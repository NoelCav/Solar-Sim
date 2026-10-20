using System;
using System.Collections.Generic;
using Godot;

namespace SolarSim;

/// <summary>Marching a ray through tile media and optical surfaces, plus the Fresnel and refraction formulas.</summary>
public partial class LightEngine
{
    // ===========================================================================================
    // Marching
    // ===========================================================================================

    /// Walks from o along d until the next event, applying bulk absorption to p on the way.
    void March(D2 o, D2 d, double[] p, int medium, int body)
    {
        double tm = _tm;
        int w = _w, h = _h;
        double gw = w * tm, gh = h * tm;
        _evT = 0;
        _evBody = body;
        _evMedium = medium;
        if (o.X < 0 || o.Y < 0 || o.X >= gw || o.Y >= gh)
        {
            double tIn = EnterT(o, d, gw, gh);
            if (tIn < 0)
            {
                _evO = o;
                _evKind = Ev.Miss;
                return;
            }
            o = o + d * (tIn + Nudge);
        }
        _evO = o;
        int[] mat = _mat;
        int cx = Math.Clamp((int)Math.Floor(o.X / tm), 0, w - 1);
        int cy = Math.Clamp((int)Math.Floor(o.Y / tm), 0, h - 1);
        int stepX = d.X > 0 ? 1 : -1;
        int stepY = d.Y > 0 ? 1 : -1;
        double tdx = d.X != 0 ? tm / Math.Abs(d.X) : double.PositiveInfinity;
        double tdy = d.Y != 0 ? tm / Math.Abs(d.Y) : double.PositiveInfinity;
        double tmx = d.X != 0 ? ((cx + (d.X > 0 ? 1 : 0)) * tm - o.X) / d.X : double.PositiveInfinity;
        double tmy = d.Y != 0 ? ((cy + (d.Y > 0 ? 1 : 0)) * tm - o.Y) / d.Y : double.PositiveInfinity;
        double t0 = 0;
        D2 face = default;
        bool hasFace = false;
        int prevMat = mat[cy * w + cx];
        if (body < 0)
        {
            if (_opaque[prevMat] == 1)   // Started in (or entered the site through) a solid tile
            {
                _evKind = Ev.StartOpaque;
                _evTile = cy * w + cx;
                _evMat = prevMat;
                _evFace = default;
                return;
            }
            medium = prevMat;
        }
        while (true)
        {
            if (cx < 0 || cy < 0 || cx >= w || cy >= h)
            {
                _evKind = Ev.Exit;
                _evT = t0;
                _evMedium = medium;
                _evBody = body;
                return;
            }
            int i = cy * w + cx;
            double t1 = Math.Min(tmx, tmy);
            // Optical surfaces bucketed in this tile.
            double bestT = double.PositiveInfinity, bestU = 0;
            int bestS = -1;
            int kEnd = _cellStart[i + 1];
            for (int k = _cellStart[i]; k < kEnd; k++)
            {
                int s = _cellItems[k];
                double sx = _ex[s], sy = _ey[s];
                double denom = d.X * sy - d.Y * sx;
                if (denom > -1e-12 && denom < 1e-12)
                    continue;
                double qx = _ax[s] - o.X, qy = _ay[s] - o.Y;
                double t = (qx * sy - qy * sx) / denom;
                if (t <= Eps || t >= bestT)
                    continue;
                double u = (qx * d.Y - qy * d.X) / denom;
                if (u < -UEps || u > 1.0 + UEps)
                    continue;
                bestT = t;
                bestS = s;
                bestU = u;
            }
            // A body ray whose stretch through this tile (up to its next surface) lies outside its
            // body's bounds slipped past a corner (grazing hit, nudge): it is in the tile medium
            // again. Up to the next surface, not the tile edge: a ray leaving the glass midway
            // through a tile is inside for that whole stretch, wherever the tile grid falls.
            double tEnd = bestS >= 0 && bestT <= t1 + Eps ? bestT : t1;
            if (body >= 0 && !(_bounds.TryGetValue(body, out R2 bb) && bb.Has(o + d * (0.5 * (t0 + tEnd)))))
            {
                body = -1;
                medium = mat[i];
                prevMat = medium;
            }
            // Tile medium boundary.
            if (body < 0 && hasFace)
            {
                int m = mat[i];
                if (m != prevMat)
                {
                    _evKind = _opaque[m] == 1 ? Ev.Opaque : Ev.Media;
                    _evT = t0;
                    _evTile = i;
                    _evFace = face;
                    _evMat = m;
                    _evPrevMat = prevMat;
                    _evMedium = medium;
                    _evBody = body;
                    return;
                }
            }
            if (bestS >= 0 && bestT <= t1 + Eps)
            {
                AbsorbLeg(p, medium, bestT - t0, i, body, o + d * t0, o + d * bestT);
                _evKind = Ev.Surface;
                _evT = bestT;
                _evSeg = bestS;
                _evU = bestU;
                _evTile = i;
                _evMedium = medium;
                _evBody = body;
                return;
            }
            AbsorbLeg(p, medium, t1 - t0, i, body, o + d * t0, o + d * t1);
            int r = _airDist[i] - 1;
            if (body < 0 && r >= 1)
            {
                // Every tile within r of this one is plain air with no surfaces: jump to where
                // the ray leaves that square.
                double ex = d.X > 0 ? ((cx + r + 1) * tm - o.X) / d.X
                    : (d.X < 0 ? ((cx - r) * tm - o.X) / d.X : double.PositiveInfinity);
                double ey = d.Y > 0 ? ((cy + r + 1) * tm - o.Y) / d.Y
                    : (d.Y < 0 ? ((cy - r) * tm - o.Y) / d.Y : double.PositiveInfinity);
                if (ex < ey)
                {
                    t0 = ex;
                    int ny = Math.Clamp((int)Math.Floor((o.Y + d.Y * t0) / tm), cy - r, cy + r);
                    cx = stepX > 0 ? cx + r + 1 : cx - r - 1;
                    cy = ny;
                    face = new D2(-stepX, 0);
                }
                else
                {
                    t0 = ey;
                    int nx = Math.Clamp((int)Math.Floor((o.X + d.X * t0) / tm), cx - r, cx + r);
                    cy = stepY > 0 ? cy + r + 1 : cy - r - 1;
                    cx = nx;
                    face = new D2(0, -stepY);
                }
                hasFace = true;
                tmx = d.X != 0 ? ((cx + (d.X > 0 ? 1 : 0)) * tm - o.X) / d.X : double.PositiveInfinity;
                tmy = d.Y != 0 ? ((cy + (d.Y > 0 ? 1 : 0)) * tm - o.Y) / d.Y : double.PositiveInfinity;
                prevMat = AirId;
                continue;
            }
            if (tmx < tmy)
            {
                cx += stepX;
                t0 = tmx;
                tmx += tdx;
                face = new D2(-stepX, 0);
            }
            else
            {
                cy += stepY;
                t0 = tmy;
                tmy += tdy;
                face = new D2(0, -stepY);
            }
            hasFace = true;
            prevMat = mat[i];
        }
    }

    /// Beer–Lambert absorption over the leg from→to (`length` m) inside `medium`; heat goes to tile i.
    void AbsorbLeg(double[] p, int medium, double length, int i, int body, D2 from, D2 to)
    {
        if (length <= 0 || _hasBulk[medium] == 0)
            return;
        for (int b = 0; b < Bins; b++)
        {
            double k = _bulk[medium * Bins + b];
            if (p[b] > 0 && k > 0)
            {
                double keep = Math.Exp(-k * length);
                DepositBin(i, b, p[b] * (1.0 - keep), body, from, to, k * length);
                p[b] *= keep;
            }
        }
    }

    D2 ShadingNormal(int s, double u)
    {
        D2 n = _na[s].Lerp(_nb[s], u).Normalized();
        return n.Dot(_n[s]) > 0 ? n : _n[s];
    }

    int TileAt(D2 pos)
    {
        int x = Math.Clamp((int)Math.Floor(pos.X / _tm), 0, _w - 1);
        int y = Math.Clamp((int)Math.Floor(pos.Y / _tm), 0, _h - 1);
        return y * _w + x;
    }

    /// 0 top, 1 bottom, 2 left, 3 right: which face of a tile, from the normal facing the ray.
    static int FaceCode(D2 face)
    {
        if (face.Y < 0)
            return 0;
        if (face.Y > 0)
            return 1;
        return face.X < 0 ? 2 : 3;
    }

    static double Fresnel(double cosI, double n1, double n2)
    {
        double eta = n1 / n2;
        double sin2T = eta * eta * (1.0 - cosI * cosI);
        if (sin2T >= 1.0)
            return 1.0;
        double cosT = Math.Sqrt(1.0 - sin2T);
        double r0 = (n1 - n2) / (n1 + n2);
        r0 *= r0;
        double c = n1 <= n2 ? cosI : cosT;
        return r0 + (1.0 - r0) * Math.Pow(1.0 - c, 5.0);
    }

    static D2 Refract(D2 d, D2 nrm, double cosI, double eta)
    {
        double cosT = Math.Sqrt(Math.Max(0.0, 1.0 - eta * eta * (1.0 - cosI * cosI)));
        return (d * eta + nrm * (eta * cosI - cosT)).Normalized();
    }

    /// Distance along the ray to enter the box [0,w]×[0,h], or -1 if it misses.
    static double EnterT(D2 o, D2 d, double w, double h)
    {
        double tNear = double.NegativeInfinity, tFar = double.PositiveInfinity;
        for (int axis = 0; axis < 2; axis++)
        {
            double hi = axis == 0 ? w : h;
            double oc = axis == 0 ? o.X : o.Y;
            double dc = axis == 0 ? d.X : d.Y;
            if (Math.Abs(dc) < 1e-12)
            {
                if (oc < 0 || oc > hi)
                    return -1;
                continue;
            }
            double ta = (0 - oc) / dc, tb = (hi - oc) / dc;
            tNear = Math.Max(tNear, Math.Min(ta, tb));
            tFar = Math.Min(tFar, Math.Max(ta, tb));
        }
        if (tNear > tFar || tFar < 0)
            return -1;
        return Math.Max(tNear, 0);
    }
}

using System;
using System.Collections.Generic;
using Godot;

namespace SolarSim;

/// <summary>The ray tree: one ray and all its children, for secondary light and tests.</summary>
public partial class LightEngine
{
    // ===========================================================================================
    // Ray tree (secondary light, tests)
    // ===========================================================================================

    /// <summary>Traces one ray and all its children (power W per bin). Counts it as emitted.</summary>
    public void Trace(Vector2 origin, Vector2 dir, float[] power)
    {
        var p = ToDouble(power);
        double total = 0;
        foreach (double v in p)
            total += v;
        _emitted += total;
        TraceTree(D2.From(origin), D2.From(dir).Normalized(), p, -1, -1);
    }

    void TraceTree(D2 origin, D2 dir, double[] power, int medium, int body)
    {
        _stack.Push(new TreeRay { O = origin, D = dir, P = power, Medium = medium, Body = body, Events = 0 });
        while (_stack.Count > 0)
        {
            var r = _stack.Pop();
            TracePath(r.O, r.D, r.P, r.Medium, r.Body, r.Events);
        }
    }

    void TracePath(D2 o, D2 d, double[] p, int medium, int body, int events)
    {
        _rayCount++;
        if (events > _maxEvents)
        {
            AddCulled(Sum(p));
            return;
        }
        var p0 = (double[])p.Clone();
        March(o, d, p, medium, body);
        D2 start = _evO;
        D2 hit = start + d * _evT;
        switch (_evKind)
        {
            case Ev.Miss:
                AddEscaped(Sum(p));
                break;
            case Ev.Exit:
                Emit(start, hit, p0);
                AddEscaped(Sum(p));
                break;
            case Ev.StartOpaque:
                AbsorbOpaque(_evTile, -1, 0, p);
                break;
            case Ev.Opaque:
            {
                Emit(start, hit, p0);
                int side = FaceCode(_evFace);
                AbsorbOpaque(_evTile, side, StripAt(_evTile, side, hit), p);
                break;
            }
            case Ev.Media:
                Emit(start, hit, p0);
                Interface(hit, d, _evFace, _evPrevMat, _evMat, p, -1, -1, events);
                break;
            case Ev.Surface:
                Emit(start, hit, p0);
                SurfaceHit(_evSeg, _evU, hit, d, p, _evMedium, _evBody, events);
                break;
        }
    }

    void AbsorbOpaque(int i, int side, int strip, double[] p)
    {
        for (int b = 0; b < Bins; b++)
            if (p[b] > 0)
                AbsorbOpaqueBin(i, side, strip, b, p[b]);
    }

    void SurfaceHit(int s, double u, D2 hit, D2 d, double[] p, int medium, int body, int events)
    {
        D2 n = _n[s];
        bool fromFront = d.Dot(n) < 0;
        int owner = _owner[s];
        switch (_coating[s])
        {
            case CoatProbe:
                for (int b = 0; b < Bins; b++)
                    AddIncident(owner, b, p[b], events == 0);
                Push(hit + d * Nudge, d, p, medium, body, events + 1);
                break;
            case CoatMirror:
            case CoatCell:
            {
                if (_coating[s] == CoatCell && fromFront)
                    for (int b = 0; b < Bins; b++)
                        AddIncident(owner, b, p[b], events == 0);
                var outP = new double[Bins];
                int tile = TileAt(hit);
                for (int b = 0; b < Bins; b++)
                {
                    outP[b] = p[b] * _refl[s * Bins + b];
                    DepositBin(tile, b, p[b] - outP[b], owner, hit, hit);
                }
                D2 r = d - n * (2.0 * d.Dot(n));
                Push(hit + r * Nudge, r, outP, medium, body, events + 1);
                break;
            }
            case CoatSplit:
            {
                // Both branches go on as rays: the reflected one and the transmitted one (straight on),
                // what the plate absorbs heats it.
                var reflected = new double[Bins];
                var passed = new double[Bins];
                int tile = TileAt(hit);
                for (int b = 0; b < Bins; b++)
                {
                    reflected[b] = p[b] * _refl[s * Bins + b];
                    passed[b] = p[b] * _trans[s * Bins + b];
                    DepositBin(tile, b, Math.Max(p[b] - reflected[b] - passed[b], 0.0), owner, hit, hit);
                }
                D2 r = d - n * (2.0 * d.Dot(n));
                PushChild(hit, d, passed, medium, body, events, _minRayW);
                PushChild(hit, r, reflected, medium, body, events, _minChildW);
                break;
            }
            default:
            {
                // Which side we hit decides inside/outside, so a ray that slipped past a corner
                // can't stay flagged as inside a body.
                D2 ns = ShadingNormal(s, u);
                if (fromFront)
                    Interface(hit, d, ns, _front[s], _back[s], p, -1, owner, events);
                else
                    Interface(hit, d, -ns, _back[s], _front[s], p, owner, -1, events);
                break;
            }
        }
    }

    /// Fresnel (Schlick) + Snell from m1 into m2; nrm faces the incoming ray. Multi-bin rays split
    /// per bin when either side is dispersive.
    void Interface(D2 hit, D2 d, D2 nrm, int m1, int m2, double[] p, int bodyRefl, int bodyTrans, int events)
    {
        double cosI = Math.Clamp(-d.Dot(nrm), 0.0, 1.0);
        bool split = (_dispersive[m1] == 1 || _dispersive[m2] == 1) && NonzeroBins(p) > 1;
        var refl = new double[Bins];
        var trans = new double[Bins];
        D2 tDir = d;
        for (int b = 0; b < Bins; b++)
        {
            if (p[b] <= 0)
                continue;
            double fr = Fresnel(cosI, _index[m1 * Bins + b], _index[m2 * Bins + b]);
            refl[b] = p[b] * fr;
            if (fr >= 1.0)
                continue;
            tDir = Refract(d, nrm, cosI, _index[m1 * Bins + b] / _index[m2 * Bins + b]);
            if (split)
            {
                var single = new double[Bins];
                single[b] = p[b] - refl[b];
                PushChild(hit, tDir, single, m2, bodyTrans, events, _minRayW);
            }
            else
                trans[b] = p[b] - refl[b];
        }
        if (!split)
            PushChild(hit, tDir, trans, m2, bodyTrans, events, _minRayW);
        PushChild(hit, d + nrm * (2.0 * cosI), refl, m1, bodyRefl, events, _minChildW);
    }

    void PushChild(D2 hit, D2 dir, double[] p, int medium, int body, int events, double minW)
    {
        double total = Sum(p);
        if (total <= 0)
            return;
        if (total < minW)
        {
            AddCulled(total);
            return;
        }
        Push(hit + dir * Nudge, dir, p, medium, body, events + 1);
    }

    void Push(D2 o, D2 d, double[] p, int medium, int body, int events) =>
        _stack.Push(new TreeRay { O = o, D = d, P = p, Medium = medium, Body = body, Events = events });

    void Emit(D2 from, D2 to, double[] p)
    {
        if (_segFrom.Count >= MaxRenderSegments)
            return;
        _segFrom.Add(from.G);
        _segTo.Add(to.G);
        for (int b = 0; b < Bins; b++)
            _segPower.Add((float)p[b]);
    }
}

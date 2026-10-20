using System;
using System.Collections.Generic;
using Godot;

namespace SolarSim;

/// <summary>Primary paths: one single-bin ray along its dominant path, recorded for the beam stage.</summary>
public partial class LightEngine
{
    // ===========================================================================================
    // Primary paths
    // ===========================================================================================

    /// Follows one ray of unit power in bin along its dominant path (transmission, or reflection
    /// under TIR), recording deposits, probe crossings and reflections. With stopOwner >= 0 a path
    /// whose first interaction is entering that convex object stops as it transmits back out.
    PathRec TracePrimary(D2 origin, D2 dir, int bin, int stopOwner = -1)
    {
        _rayCount++;
        var rec = new PathRec { Bin = bin };
        rec.Pts.Add(origin);
        rec.Frac.Add(1.0);
        RunPrimary(rec, origin, dir.Normalized(), -1, -1, 0, stopOwner);
        return rec;
    }

    void ContinuePrimary(PathRec rec) => RunPrimary(rec, rec.ContO, rec.ContD, -1, -1, rec.ContEvents, -1);

    void RunPrimary(PathRec rec, D2 o, D2 d, int medium, int body, int firstEvent, int stopOwner)
    {
        int bin = rec.Bin;
        var p = new double[Bins];
        p[bin] = rec.Remain;
        rec.Term = Term.Culled;
        _rec = rec;
        for (int events = firstEvent; events <= _maxEvents; events++)
        {
            March(o, d, p, medium, body);
            medium = _evMedium;
            body = _evBody;
            D2 hit = _evO + d * _evT;
            bool leaving = false;
            if (stopOwner >= 0 && events == firstEvent && (_evKind != Ev.Surface || _owner[_evSeg] != stopOwner))
                stopOwner = -1;   // Didn't meet the object first: nothing to stop at
            bool stop = false;
            switch (_evKind)
            {
                case Ev.Miss:
                    rec.Term = Term.Escape;
                    stop = true;
                    break;
                case Ev.Exit:
                    rec.Pts.Add(hit);
                    rec.Frac.Add(p[bin]);
                    rec.Term = Term.Escape;
                    stop = true;
                    break;
                case Ev.StartOpaque:
                case Ev.Opaque:
                    rec.Pts.Add(hit);
                    rec.Frac.Add(p[bin]);
                    rec.Term = Term.Opaque;
                    rec.TermTile = _evTile;
                    rec.TermSide = _evKind == Ev.StartOpaque ? -1 : FaceCode(_evFace);
                    stop = true;
                    break;
                case Ev.Media:
                    rec.Sig.Add(-1 - ((_evPrevMat * 1024 + _evMat) * 4 + FaceCode(_evFace)));
                    d = PrimaryInterface(rec, hit, d, _evFace, _evPrevMat, _evMat, p, -1);
                    medium = d.Dot(_evFace) > 0 ? _evPrevMat : _evMat;   // TIR stays in the old medium
                    body = -1;
                    break;
                case Ev.Surface:
                {
                    int s = _evSeg;
                    D2 n = _n[s];
                    bool fromFront = d.Dot(n) < 0;
                    int owner = _owner[s];
                    if (_coating[s] == CoatProbe)
                    {
                        // A probe only reads what crosses it: no event in the path, so rays on
                        // either side of its ends still make one beam (no split, no seam).
                        rec.Incident.Add(owner);
                        rec.Incident.Add(p[bin]);
                        rec.Incident.Add(rec.Sig.Count == 0 ? 1 : 0);
                        o = hit + d * Nudge;
                        continue;
                    }
                    if (_coating[s] == CoatSplit)
                    {
                        // Fork: this run is traced once per combination of branches (the task's mask:
                        // bit j set = reflect at the j-th splitter met), each carrying its share. A
                        // variant records only what comes after its last reflection: what came before
                        // was recorded by the variants that took the other branches.
                        int j = rec.Forks++;
                        double rr = _refl[s * Bins + bin], tt = _trans[s * Bins + bin];
                        if (((_mask >> j) & 1) != 0)
                        {
                            if ((_mask >> (j + 1)) == 0)
                            {
                                rec.Deps.Clear();
                                rec.Incident.Clear();
                                rec.Refls.Clear();
                                rec.Start = rec.Pts.Count;
                            }
                            rec.Sig.Add(_piece[s] * 2 + (fromFront ? 0 : 1) + SplitSig);
                            p[bin] *= rr;
                            d = d - n * (2.0 * d.Dot(n));
                        }
                        else
                        {
                            DepositBin(TileAt(hit), bin, p[bin] * Math.Max(1.0 - rr - tt, 0.0), owner, hit, hit);
                            p[bin] *= tt;
                        }
                        break;
                    }
                    bool direct = rec.Sig.Count == 0;   // Nothing redirected it before this surface
                    rec.Sig.Add(_piece[s] * 2 + (fromFront ? 0 : 1));
                    if (_coating[s] == CoatMirror || _coating[s] == CoatCell)
                    {
                        if (_coating[s] == CoatCell && fromFront)
                        {
                            rec.Incident.Add(owner);
                            rec.Incident.Add(p[bin]);
                            rec.Incident.Add(direct ? 1 : 0);
                        }
                        double keep = p[bin] * _refl[s * Bins + bin];
                        DepositBin(TileAt(hit), bin, p[bin] - keep, owner, hit, hit);
                        p[bin] = keep;
                        d = d - n * (2.0 * d.Dot(n));
                    }
                    else
                    {
                        D2 ns = ShadingNormal(s, _evU);
                        D2 nrm = fromFront ? ns : -ns;
                        int m1 = fromFront ? _front[s] : _back[s];
                        int m2 = fromFront ? _back[s] : _front[s];
                        int reflBody = fromFront ? -1 : owner;
                        d = PrimaryInterface(rec, hit, d, nrm, m1, m2, p, reflBody);
                        if (d.Dot(nrm) > 0)   // TIR
                        {
                            medium = m1;
                            body = reflBody;
                        }
                        else
                        {
                            medium = m2;
                            body = fromFront ? owner : -1;
                            leaving = !fromFront && owner == stopOwner;
                        }
                    }
                    break;
                }
            }
            if (stop)
                break;
            rec.Pts.Add(hit);
            rec.Frac.Add(p[bin]);
            o = hit + d * Nudge;
            if (p[bin] < 1e-9)
            {
                rec.Term = Term.Culled;
                break;
            }
            if (leaving)
            {
                rec.Term = Term.Pending;
                rec.ContO = o;
                rec.ContD = d;
                rec.ContEvents = events + 1;
                break;
            }
        }
        rec.Remain = p[bin];
        _rec = null;
        _runForks = Math.Max(_runForks, rec.Forks);
        if (rec.Term != Term.Pending && (_mask >> rec.Forks) != 0)
        {
            // This variant reflects at a splitter the ray never met: nothing to count.
            rec.Invalid = true;
            rec.Term = Term.Culled;
            rec.Remain = 0.0;
            rec.Deps.Clear();
            rec.Incident.Clear();
            rec.Refls.Clear();
        }
    }

    D2 PrimaryInterface(PathRec rec, D2 hit, D2 d, D2 nrm, int m1, int m2, double[] p, int reflBody)
    {
        int bin = rec.Bin;
        double cosI = Math.Clamp(-d.Dot(nrm), 0.0, 1.0);
        double n1 = _index[m1 * Bins + bin], n2 = _index[m2 * Bins + bin];
        double fr = Fresnel(cosI, n1, n2);
        D2 rDir = d + nrm * (2.0 * cosI);
        if (fr >= 1.0)
            return rDir;
        rec.Refls.Add(hit.X);
        rec.Refls.Add(hit.Y);
        rec.Refls.Add(rDir.X);
        rec.Refls.Add(rDir.Y);
        rec.Refls.Add(p[bin] * fr);
        rec.Refls.Add(m1);
        rec.Refls.Add(reflBody);
        p[bin] *= 1.0 - fr;
        return Refract(d, nrm, cosI, n1 / n2);
    }
}

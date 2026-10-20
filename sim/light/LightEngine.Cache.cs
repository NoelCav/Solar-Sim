using System;
using System.Collections.Generic;
using Godot;

namespace SolarSim;

/// <summary>The object cache: identical objects share their sample paths, placed at each object.</summary>
public partial class LightEngine
{
    PathRec TraceAt(double u, double s0, int bin)
    {
        D2 origin = _perp * u + _dir * s0;
        if (_runObj == null || !CacheEnabled)
            return TracePrimary(origin, _dir, bin);
        var key = (_runObj.DefIdx, _runObj.AngleQ, bin, (long)Math.Round((u - _runObj.Uc) * 1e6));
        if (_cache.TryGetValue(key, out PathRec local))
        {
            // The cached part is only valid if this ray reaches this object where the cached one
            // reached its own: another object or tile in the way (e.g. a lens above this one)
            // changes everything after.
            if (local != null && EntersAt(origin, bin, local.Pts[1] + _runObj.Pos))
            {
                _cacheHits++;
                PathRec rec = Instantiate(local);
                rec.Pts[0] = origin;
                _rayCount++;
                ContinuePrimary(rec);
                return rec;
            }
            PathRec own = TracePrimary(origin, _dir, bin, _runId);
            if (own.Term == Term.Pending)
                ContinuePrimary(own);
            return own;
        }
        _cacheMisses++;
        PathRec fresh = TracePrimary(origin, _dir, bin, _runId);
        _cache[key] = fresh.Term == Term.Pending ? Localize(fresh) : null;
        if (fresh.Term == Term.Pending)
            ContinuePrimary(fresh);
        return fresh;
    }

    readonly PathRec _scratch = new();
    readonly double[] _scratchP = new double[Bins];

    /// Whether a sun ray from `origin` first meets the run's object at `entry`.
    bool EntersAt(D2 origin, int bin, D2 entry)
    {
        PathRec saved = _rec;
        _rec = _scratch;   // Nothing on the way should deposit; anything that does is dropped
        Array.Clear(_scratchP);
        _scratchP[bin] = 1.0;
        March(origin, _dir, _scratchP, -1, -1);
        _rec = saved;
        _scratch.Deps.Clear();
        if (_evKind != Ev.Surface || _owner[_evSeg] != _runId)
            return false;
        D2 hit = _evO + _dir * _evT;
        D2 off = hit - entry;
        return off.X * off.X + off.Y * off.Y < 1e-12;
    }

    /// Copy of the object part of a path relative to the object: positions minus its position,
    /// its pieces numbered from 0, its id as -2.
    PathRec Localize(PathRec rec)
    {
        if (rec.Incident.Count > 0)
            return null;
        D2 off = _runObj.Pos;
        int fp = _runObj.FirstPiece;
        var c = new PathRec { Bin = rec.Bin };
        foreach (var pt in rec.Pts)
            c.Pts.Add(pt - off);
        c.Frac.AddRange(rec.Frac);
        foreach (int v in rec.Sig)
            c.Sig.Add(v >= 0 ? v - 2 * fp : v);
        var deps = rec.Deps;
        for (int k = 0; k < deps.Count; k += 8)
        {
            c.Deps.Add(-1);
            c.Deps.Add(deps[k + 1]);
            c.Deps.Add(deps[k + 2] >= 0 ? -2 : deps[k + 2]);
            c.Deps.Add(deps[k + 3] - off.X);
            c.Deps.Add(deps[k + 4] - off.Y);
            c.Deps.Add(deps[k + 5] - off.X);
            c.Deps.Add(deps[k + 6] - off.Y);
            c.Deps.Add(deps[k + 7]);
        }
        var refls = rec.Refls;
        for (int k = 0; k < refls.Count; k += 7)
        {
            c.Refls.Add(refls[k] - off.X);
            c.Refls.Add(refls[k + 1] - off.Y);
            c.Refls.Add(refls[k + 2]);
            c.Refls.Add(refls[k + 3]);
            c.Refls.Add(refls[k + 4]);
            c.Refls.Add(refls[k + 5]);
            c.Refls.Add(refls[k + 6] >= 0 ? -2 : refls[k + 6]);
        }
        c.Term = Term.Pending;
        c.ContO = rec.ContO - off;
        c.ContD = rec.ContD;
        c.ContEvents = rec.ContEvents;
        c.Remain = rec.Remain;
        return c;
    }

    /// A cached object part placed on the current run's object, ready to continue.
    PathRec Instantiate(PathRec c)
    {
        D2 off = _runObj.Pos;
        int fp = _runObj.FirstPiece;
        var r = new PathRec { Bin = c.Bin };
        foreach (var pt in c.Pts)
            r.Pts.Add(pt + off);
        r.Frac.AddRange(c.Frac);
        foreach (int v in c.Sig)
            r.Sig.Add(v >= 0 ? v + 2 * fp : v);
        var deps = c.Deps;
        for (int k = 0; k < deps.Count; k += 8)
        {
            var a = new D2(deps[k + 3] + off.X, deps[k + 4] + off.Y);
            var b = new D2(deps[k + 5] + off.X, deps[k + 6] + off.Y);
            int body = deps[k + 2] == -2 ? _runId : (int)deps[k + 2];
            SplitDeposit(r, deps[k + 1], body, a, b, deps[k + 7]);
        }
        var refls = c.Refls;
        for (int k = 0; k < refls.Count; k += 7)
        {
            r.Refls.Add(refls[k] + off.X);
            r.Refls.Add(refls[k + 1] + off.Y);
            r.Refls.Add(refls[k + 2]);
            r.Refls.Add(refls[k + 3]);
            r.Refls.Add(refls[k + 4]);
            r.Refls.Add(refls[k + 5]);
            r.Refls.Add(refls[k + 6] == -2 ? _runId : refls[k + 6]);
        }
        r.Term = Term.Pending;
        r.ContO = c.ContO + off;
        r.ContD = c.ContD;
        r.ContEvents = c.ContEvents;
        r.Remain = c.Remain;
        return r;
    }
}

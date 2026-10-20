using System;
using System.Collections.Generic;
using Godot;

namespace SolarSim;

/// <summary>The beam stage: tasks per run and bin, adaptive wavefront refinement, landing, pooled reflections.</summary>
public partial class LightEngine
{
    // ===========================================================================================
    // Beam tasks (stage 2)
    // ===========================================================================================

    /// <summary>
    /// Sets up the beam stage. `runs` holds (first lane, last lane, key) per optical run and
    /// `sMins` its first-hit depth; `objects` maps cacheable object ids to
    /// [definition index, angle key, first piece, position, u of center, s of start line].
    /// With `prev` and `reuse`, tasks whose run is unchanged and whose rays came nowhere near the
    /// changed `areas` (x, y, w, h in meters) are replayed from prev instead of traced.
    /// </summary>
    public void StartBeams(int[] runs, double[] sMins, float[] irradiance, double u0, double laneW, Vector2 perp,
        Vector2 dir, Godot.Collections.Dictionary objects, LightEngine prev, float[] areas, bool reuse)
    {
        _src = new Source { U0 = u0, LaneW = laneW, Perp = D2.From(perp), Dir = D2.From(dir) };
        for (int b = 0; b < Bins; b++)
            _src.Irradiance[b] = irradiance[b];
        _objects.Clear();
        foreach (var kv in objects)
        {
            var a = (Godot.Collections.Array)kv.Value;
            _objects[(int)kv.Key] = new ObjInfo
            {
                DefIdx = (int)a[0], AngleQ = (long)a[1], FirstPiece = (int)a[2], Pos = D2.From((Vector2)a[3]),
                Uc = (double)a[4], S0 = (double)a[5],
            };
        }
        var changed = new List<R2>();
        for (int k = 0; k + AreaRect - 1 < areas.Length; k += AreaRect)
            changed.Add(new R2(areas[k], areas[k + 1], areas[k] + areas[k + 2], areas[k + 1] + areas[k + 3]));
        _tasks.Clear();
        _next = 0;
        for (int r = 0; r * 3 + 2 < runs.Length; r++)
        {
            int k0 = runs[r * 3], k1 = runs[r * 3 + 1], key = runs[r * 3 + 2];
            for (int b = 0; b < Bins; b++)
            {
                if (_src.Irradiance[b] <= 0)
                    continue;
                TaskLog old = null;
                if (reuse && prev != null && prev._logs.TryGetValue((k0, k1, key, b), out TaskLog l)
                    && l.SMin == sMins[r] && !Touches(l, changed))
                    old = l;
                _tasks.Add(new Task { K0 = k0, K1 = k1, Key = key, Bin = b, SMin = sMins[r], Replay = old });
            }
        }
    }

    public int TaskCount() => _tasks.Count;

    /// <summary>Fraction of beam tasks done.</summary>
    public double Progress() => _tasks.Count == 0 ? 1.0 : (double)_next / _tasks.Count;

    /// <summary>
    /// Runs beam tasks until about `budget` ray paths' worth of work is done (-1 = finish); a
    /// replayed task counts by the size of its log. Returns true when all tasks are done.
    /// </summary>
    public bool Step(int budget)
    {
        double limit = budget >= 0 ? budget : double.PositiveInfinity;
        int start = _rayCount;
        double replayWork = 0;
        while (_next < _tasks.Count && _rayCount - start + replayWork < limit)
        {
            Task t = _tasks[_next];
            TaskLog log = t.Replay;
            if (log != null)
            {
                Replay(log);
                _replayed++;
                replayWork += (log.Deps.Count / LogDep) / ReplayDepsPerPath;
            }
            else
                log = TraceRun(t);
            if (log != null)
                _logs[(log.K0, log.K1, log.Key, log.Bin)] = log;
            _next++;
        }
        return _next >= _tasks.Count;
    }

    void Replay(TaskLog t)
    {
        var deps = t.Deps;
        for (int k = 0; k < deps.Count; k += LogDep)
            ApplyBin((int)deps[k], (int)deps[k + 1], deps[k + 2], (int)deps[k + 3]);
        var incident = t.Incident;
        for (int k = 0; k < incident.Count; k += PathIncident)
        {
            int slot = (int)incident[k + 1];
            AddIncident((int)incident[k], slot % Bins, incident[k + 2], slot < Bins);
        }
        var strips = t.Strips;
        for (int k = 0; k < strips.Count; k += LogStrip)
            AddStrip((int)strips[k], (float)strips[k + 1], (float)strips[k + 2]);
        _escaped += t.Escaped;
        _scattered += t.Scattered;
        _culled += t.Culled;
        _segFrom.AddRange(t.SegFrom);
        _segTo.AddRange(t.SegTo);
        _segPower.AddRange(t.SegPower);
        _render.AddRange(t.Render);
    }

    /// Whether a logged task's rays came near any changed area: its beam bounds, or any of its
    /// secondary rays (as segments).
    static bool Touches(TaskLog log, List<R2> areas)
    {
        R2 b = log.BBox.Grow(0.01);
        foreach (var area in areas)
        {
            R2 a = area.Grow(0.01);
            if (b.Intersects(a))
                return true;
            for (int k = 0; k < log.SegFrom.Length; k++)
                if (SegmentHitsRect(D2.From(log.SegFrom[k]), D2.From(log.SegTo[k]), a))
                    return true;
        }
        return false;
    }

    /// Liang–Barsky: does segment p0–p1 pass through rect r?
    static bool SegmentHitsRect(D2 p0, D2 p1, R2 r)
    {
        double t0 = 0, t1 = 1;
        for (int axis = 0; axis < 2; axis++)
        {
            double lo = axis == 0 ? r.X0 : r.Y0, hi = axis == 0 ? r.X1 : r.Y1;
            double p = axis == 0 ? p0.X : p0.Y;
            double dd = axis == 0 ? p1.X - p0.X : p1.Y - p0.Y;
            if (Math.Abs(dd) < 1e-12)
            {
                if (p < lo || p > hi)
                    return false;
                continue;
            }
            double ta = (lo - p) / dd, tb = (hi - p) / dd;
            t0 = Math.Max(t0, Math.Min(ta, tb));
            t1 = Math.Min(t1, Math.Max(ta, tb));
            if (t0 > t1)
                return false;
        }
        return true;
    }

    /// Traces one run in one bin and returns the log of what it contributed.
    TaskLog TraceRun(Task task)
    {
        int bin = task.Bin;
        if (_src.Irradiance[bin] <= 0)
            return null;
        var log = new TaskLog { K0 = task.K0, K1 = task.K1, Key = task.Key, Bin = bin, SMin = task.SMin };
        _log = log;
        int paths0 = _rayCount;
        int seg0 = _segFrom.Count;
        int render0 = _render.Count;
        _bboxEmpty = true;
        double uLo = _src.Edge(task.K0);
        double uHi = _src.Edge(task.K1 + 1);
        _runId = task.Key;
        _runObj = _objects.TryGetValue(_runId, out ObjInfo info) ? info : null;
        double s0 = task.SMin - 0.02;
        var us = new List<double> { uLo };
        // Samples on a grid fixed to the run's object (glass tiles: to the world), so as the sun
        // moves they slide with the object instead of being re-spread between the run's
        // lane-quantized edges each pass (which made caustics pop); identical cached objects
        // also ask for identical rays.
        double uc = 0;
        if (_runObj != null)
        {
            s0 = _runObj.S0;
            uc = _runObj.Uc;
        }
        else if (_anchor.TryGetValue(_runId, out D2 anchor))
            uc = _src.Coordinate(anchor);
        int j0 = (int)Math.Ceiling((uLo - uc) / BaseSpacing + 1e-6);
        int j1 = (int)Math.Floor((uHi - uc) / BaseSpacing - 1e-6);
        for (int j = j0; j <= j1; j++)
            us.Add(uc + j * BaseSpacing);
        us.Add(uHi);
        _intervals.Clear();
        _pool.Clear();
        double prevU = us[0];
        PathRec prevR = TraceAt(prevU, s0, bin);
        for (int i = 1; i < us.Count; i++)
        {
            double u = us[i];
            PathRec r = TraceAt(u, s0, bin);
            Refine(prevU, prevR, u, r, s0, bin);
            prevU = u;
            prevR = r;
        }
        foreach (var iv in _intervals)
            Settle(iv, bin);
        FlushReflections(bin);
        _intervals.Clear();
        _log = null;
        log.Compact();
        foreach (int k in s_taskIds)
        {
            log.Strips.Add(k);
            log.Strips.Add(s_task[2 * k]);
            log.Strips.Add(s_task[2 * k + 1]);
            s_task[2 * k] = s_task[2 * k + 1] = 0f;
        }
        s_taskIds.Clear();
        log.Paths = _rayCount - paths0;
        log.Render = _render.GetRange(render0, _render.Count - render0).ToArray();
        log.SegFrom = _segFrom.GetRange(seg0, _segFrom.Count - seg0).ToArray();
        log.SegTo = _segTo.GetRange(seg0, _segTo.Count - seg0).ToArray();
        log.SegPower = _segPower.GetRange(seg0 * Bins, _segPower.Count - seg0 * Bins).ToArray();
        // Secondary rays travel far (reflections leave toward the sky), so they are checked as
        // segments rather than widening the beam's bounds.
        log.BBox = _bbox;
        return log;
    }

    void Grow(D2 p)
    {
        if (_bboxEmpty)
        {
            _bbox = new R2(p.X, p.Y, p.X, p.Y);
            _bboxEmpty = false;
        }
        else
            _bbox = _bbox.Expand(p);
    }

    void Refine(double ua, PathRec ra, double ub, PathRec rb, double s0, int bin)
    {
        Span kind = Classify(ra, rb);
        if (kind != Span.Split)
        {
            _intervals.Add(new Interval { Ua = ua, Ra = ra, Ub = ub, Rb = rb, Kind = kind });
            return;
        }
        if (ub - ua <= MinSpacing)
        {
            _intervals.Add(new Interval { Ua = ua, Ra = ra, Ub = ub, Rb = rb, Kind = Span.Split });
            return;
        }
        double um = (ua + ub) * 0.5;
        PathRec rm = TraceAt(um, s0, bin);
        Refine(ua, ra, um, rm, s0, bin);
        Refine(um, rm, ub, rb, s0, bin);
    }

    /// EXACT: same optical path, landing on one straight stretch of surface (or both escape);
    /// NEAR: same path, landing within LandingTol on uneven ground; SPLIT: different paths.
    Span Classify(PathRec ra, PathRec rb)
    {
        if (ra.Term != rb.Term || ra.Term == Term.Culled)
            return Span.Split;
        if (ra.Pts.Count != rb.Pts.Count || !SameSig(ra, rb))
            return Span.Split;
        if (ra.Term != Term.Opaque)
            return Span.Exact;
        if (OneSurface(ra, rb))
            return Span.Exact;
        D2 ea = ra.Pts[^1], eb = rb.Pts[^1];
        return ea.DistanceTo(eb) <= LandingTol ? Span.Near : Span.Split;
    }

    static bool SameSig(PathRec a, PathRec b)
    {
        if (a.Sig.Count != b.Sig.Count)
            return false;
        for (int k = 0; k < a.Sig.Count; k++)
            if (a.Sig[k] != b.Sig[k])
                return false;
        return true;
    }

    /// Whether the two rays land on one straight run of exposed faces of the same orientation
    /// (one face, or consecutive tiles in a row or column), so the beam between them lands
    /// evenly along that line.
    bool OneSurface(PathRec ra, PathRec rb)
    {
        int code = ra.TermSide;
        if (code != rb.TermSide || code < 0)
            return false;
        int ta = ra.TermTile, tb = rb.TermTile;
        bool horizontal = code <= 1;
        if ((horizontal ? ta / _w : ta % _w) != (horizontal ? tb / _w : tb % _w))
            return false;
        int step = horizontal ? 1 : _w;
        for (int t = Math.Min(ta, tb); t <= Math.Max(ta, tb); t += step)
        {
            // The face must be exposed: an opaque tile with a transparent neighbour on that side.
            int nb = code == 0 ? t - _w : (code == 1 ? t + _w : (code == 2 ? t - 1 : t + 1));
            if (_opaque[_mat[t]] == 0 || (nb >= 0 && nb < _mat.Length && _opaque[_mat[nb]] == 1))
                return false;
        }
        return true;
    }

    /// A coherent beam of `watts` landing on one surface (OneSurface) between the rays' end
    /// points: spread evenly along the landing, each strip's light recorded, each tile's
    /// absorption deposited once.
    void AbsorbLanding(PathRec ra, PathRec rb, int bin, double watts)
    {
        int code = ra.TermSide;
        bool horizontal = code <= 1;
        D2 pa = ra.Pts[^1], pb = rb.Pts[^1];
        double lo = horizontal ? Math.Min(pa.X, pb.X) : Math.Min(pa.Y, pb.Y);
        double hi = horizontal ? Math.Max(pa.X, pb.X) : Math.Max(pa.Y, pb.Y);
        if (hi - lo <= 1e-9)
        {
            AbsorbOpaqueBin(ra.TermTile, code, StripAt(ra.TermTile, code, pa), bin, watts);
            return;
        }
        int ta = ra.TermTile, tb = rb.TermTile;
        int step = horizontal ? 1 : _w;
        double sw = _tm / _strips;
        for (int t = Math.Min(ta, tb); t <= Math.Max(ta, tb); t += step)
        {
            double t0 = (horizontal ? t % _w : t / _w) * _tm;   // Where this tile's face starts
            double absorb = _surfAbs[_mat[t] * Bins + bin];
            double tileIn = 0, perMeter = watts / (hi - lo);
            int k0 = Math.Max((int)Math.Floor((lo - t0) / sw), 0), k1 = Math.Min((int)Math.Ceiling((hi - t0) / sw), _strips);
            int first = (t * 4 + code) * _strips;
            for (int k = k0; k < k1; k++)
            {
                double overlap = Math.Min(hi, t0 + (k + 1) * sw) - Math.Max(lo, t0 + k * sw);
                if (overlap <= 0.0)
                    continue;
                double arriving = perMeter * overlap;
                AddStrip(first + k, (float)arriving, (float)(arriving * absorb));
                tileIn += arriving;
            }
            ApplyBin(t, bin, tileIn * absorb);
            AddScattered(tileIn * (1.0 - absorb));
        }
    }

    void Settle(Interval iv, int bin)
    {
        PathRec ra = iv.Ra, rb = iv.Rb;
        double half = _src.Watts(bin, iv.Ua, iv.Ub, _depth) * 0.5;   // W each ray carries for this interval
        foreach (var p in ra.Pts)
            Grow(p);
        foreach (var p in rb.Pts)
            Grow(p);
        // A coherent interval (both rays cross the same faces) is one beam: what it deposits in
        // tile media is spread over the band each ray stands for, not left on the ray, so the
        // light absorbed in water or glass tiles doesn't jump as the samples slide across tiles.
        bool coherent = iv.Kind != Span.Split;
        ApplyPath(ra, half, bin, iv.Ua, coherent ? rb : null);
        ApplyPath(rb, half, bin, iv.Ub, coherent ? ra : null);
        switch (iv.Kind)
        {
            case Span.Exact:
            {
                double arriving = half * (ra.Remain + rb.Remain);
                if (ra.Term == Term.Escape)
                    AddEscaped(arriving);
                else
                    AbsorbLanding(ra, rb, bin, arriving);
                RenderStrip(ra, rb, half * 2.0, bin);
                break;
            }
            case Span.Near:
                LandBand(ra, rb, half, bin);
                RenderStrip(ra, rb, half * 2.0, bin);
                break;
            default:
                Terminal(ra, half, bin);
                Terminal(rb, half, bin);
                RenderSplit(ra, rb, half, (iv.Ub - iv.Ua) * 0.5, bin);
                break;
        }
    }

    /// Adds a recorded deposit to path r, split over the tiles its leg a→b crosses here in
    /// proportion to Beer–Lambert absorption along it (optical depth tau); a point goes whole
    /// to its tile. Exact for any offset of the leg from the tile grid.
    void SplitDeposit(PathRec r, double frac, int body, D2 a, D2 b, double tau)
    {
        TileShares(a, b, tau);
        var sh = _shares;
        for (int j = 0; j < sh.Count; j += 7)
            AddDep(r, (int)sh[j], frac * sh[j + 1], body, new D2(sh[j + 2], sh[j + 3]), new D2(sh[j + 4], sh[j + 5]),
                sh[j + 6]);
    }

    /// How a leg a→b of optical depth tau absorbs across the tiles it crosses (Beer–Lambert along
    /// it; a point goes whole to its tile): fills _shares with (tile, share, ax, ay, bx, by, tau)
    /// per piece, shares summing to 1.
    void TileShares(D2 a, D2 b, double tau)
    {
        var sh = _shares;
        sh.Clear();
        D2 d = b - a;
        if (d.X * d.X + d.Y * d.Y < 1e-24)
        {
            sh.Add(TileAt(a)); sh.Add(1.0); sh.Add(a.X); sh.Add(a.Y); sh.Add(a.X); sh.Add(a.Y); sh.Add(0.0);
            return;
        }
        // Tile-boundary crossings along the leg, as fractions of its length.
        var ts = _splitTs;
        ts.Clear();
        ts.Add(0.0);
        for (int axis = 0; axis < 2; axis++)
        {
            double p0 = axis == 0 ? a.X : a.Y, dd = axis == 0 ? d.X : d.Y;
            if (Math.Abs(dd) < 1e-15)
                continue;
            double lo = Math.Min(p0, p0 + dd), hi = Math.Max(p0, p0 + dd);
            for (double g = Math.Floor(lo / _tm + 1.0) * _tm; g < hi; g += _tm)
                ts.Add((g - p0) / dd);
        }
        ts.Add(1.0);
        ts.Sort();
        double norm = tau > 1e-9 ? 1.0 - Math.Exp(-tau) : 1.0;
        for (int j = 0; j + 1 < ts.Count; j++)
        {
            double t0 = ts[j], t1 = ts[j + 1];
            if (t1 - t0 < 1e-12)
                continue;
            double w = tau > 1e-9 ? (Math.Exp(-tau * t0) - Math.Exp(-tau * t1)) / norm : t1 - t0;
            D2 p0 = a + d * t0, p1 = a + d * t1;
            sh.Add(TileAt(a + d * (0.5 * (t0 + t1)))); sh.Add(w);
            sh.Add(p0.X); sh.Add(p0.Y); sh.Add(p1.X); sh.Add(p1.Y); sh.Add(tau * (t1 - t0));
        }
    }

    readonly List<double> _splitTs = new();
    readonly List<double> _shares = new();

    static void AddDep(PathRec r, int tile, double frac, int body, D2 a, D2 b, double tau)
    {
        r.Deps.Add(tile);
        r.Deps.Add(frac);
        r.Deps.Add(body);
        r.Deps.Add(a.X);
        r.Deps.Add(a.Y);
        r.Deps.Add(b.X);
        r.Deps.Add(b.Y);
        r.Deps.Add(tau);
    }

    /// Applies a path's recorded deposits, probe crossings and reflections for `watts` of input.
    /// With `partner` (the other ray of a coherent interval), deposits in tile media are spread
    /// over the half of the interval this ray stands for: copies of each leg shifted toward the
    /// matching leg of the partner, re-split over the tiles each copy crosses. Bodies keep theirs
    /// (an object's heat doesn't depend on where in it the light was absorbed).
    void ApplyPath(PathRec r, double watts, int bin, double u, PathRec partner = null)
    {
        var deps = r.Deps;
        bool spread = partner != null && partner.Pts.Count == r.Pts.Count && r.Pts.Count >= 2;
        for (int k = 0; k < deps.Count; k += PathDep)
        {
            int body = (int)deps[k + 2];
            if (!spread || body >= 0)
            {
                ApplyBin((int)deps[k], bin, watts * deps[k + 1], body);
                continue;
            }
            D2 a = new D2(deps[k + 3], deps[k + 4]), b = new D2(deps[k + 5], deps[k + 6]);
            D2 offA = PartnerOffset(r, partner, a), offB = PartnerOffset(r, partner, b);
            double reach = 0.5 * Math.Sqrt(Math.Max(offA.Dot(offA), offB.Dot(offB)));
            int n = Math.Clamp((int)Math.Ceiling(reach / SpreadStep), 1, 16);
            double w = watts * deps[k + 1] / n;
            for (int m = 0; m < n; m++)
            {
                double f = 0.5 * (m + 0.5) / n;
                TileShares(a + offA * f, b + offB * f, deps[k + 7]);
                var sh = _shares;
                for (int j = 0; j < sh.Count; j += 7)
                    ApplyBin((int)sh[j], bin, w * sh[j + 1], -1);
            }
        }
        var incident = r.Incident;
        for (int k = 0; k < incident.Count; k += PathIncident)
            AddIncident((int)incident[k], bin, watts * incident[k + 1], incident[k + 2] > 0.5);
        var refls = r.Refls;
        for (int k = 0, idx = 0; k < refls.Count; k += PathRefl, idx++)
        {
            while (_pool.Count <= idx)
                _pool.Add(null);
            double w = watts * refls[k + 4];
            double dx = refls[k + 2], dy = refls[k + 3];
            int medium = (int)refls[k + 5], body = (int)refls[k + 6];
            long cell = (long)Math.Floor(u / _reflPool);
            ReflPool pool = _pool[idx];
            if (pool != null && pool.Samples.Count > 0)
            {
                int last = pool.Samples.Count - PoolSample;
                bool turned = dx * pool.Samples[last + 3] + dy * pool.Samples[last + 4] < ReflSplitCos;
                if (pool.Cell != cell || turned || pool.Medium != medium || pool.Body != body)
                    EmitPool(pool, bin);
            }
            pool ??= _pool[idx] = new ReflPool();
            if (pool.Samples.Count == 0)
            {
                pool.Cell = cell;
                pool.Medium = medium;
                pool.Body = body;
            }
            pool.Watts += w;
            pool.Samples.Add(w);
            pool.Samples.Add(refls[k]);
            pool.Samples.Add(refls[k + 1]);
            pool.Samples.Add(dx);
            pool.Samples.Add(dy);
        }
    }

    /// Where point p on ray r's path lies on the partner ray's path (same segment, same fraction
    /// along it), as an offset from p. Coherent rays cross the same faces, so their paths have
    /// matching segments.
    static D2 PartnerOffset(PathRec r, PathRec partner, D2 p)
    {
        int best = 0;
        double bestD = double.PositiveInfinity, bestT = 0;
        for (int j = 0; j + 1 < r.Pts.Count; j++)
        {
            D2 s0 = r.Pts[j], seg = r.Pts[j + 1] - s0;
            double len2 = seg.Dot(seg);
            double t = len2 > 1e-24 ? Math.Clamp((p - s0).Dot(seg) / len2, 0.0, 1.0) : 0.0;
            D2 q = s0 + seg * t - p;
            double dist = q.Dot(q);
            if (dist < bestD)
            {
                bestD = dist;
                best = j;
                bestT = t;
            }
        }
        return partner.Pts[best].Lerp(partner.Pts[best + 1], bestT) - p;
    }

    /// A NEAR beam (same path, landing on uneven ground): its light lands where the band between
    /// the rays really meets the ground, not on the two rays' landing points (that would make
    /// light hop between tiles as the samples slide). Sub-rays across the band, `SpreadStep`
    /// apart, re-trace only the last leg (from between the rays' last events, in between their
    /// directions; nothing on it absorbs, the rays' Remain already counts that) and the band's
    /// power, interpolated between the rays, lands where each meets an opaque face. A sub-ray that
    /// meets anything else gives its share to the nearer ray's landing.
    void LandBand(PathRec ra, PathRec rb, double half, int bin)
    {
        D2 a0 = ra.Pts[^2], a1 = ra.Pts[^1], b0 = rb.Pts[^2], b1 = rb.Pts[^1];
        double wa = half * ra.Remain, wb = half * rb.Remain;
        int n = Math.Clamp((int)Math.Ceiling(a1.DistanceTo(b1) / SpreadStep), 1, 32);
        var none = _noPower;
        for (int m = 0; m < n; m++)
        {
            double f = (m + 0.5) / n;
            double w = (wa + (wb - wa) * f) * 2.0 / n;
            D2 o = a0.Lerp(b0, f), d = (a1.Lerp(b1, f) - o).Normalized();
            March(o + d * Nudge, d, none, 0, -1);
            if (_evKind == Ev.Opaque)
            {
                D2 hit = _evO + d * _evT;
                int side = FaceCode(_evFace);
                AbsorbOpaqueBin(_evTile, side, StripAt(_evTile, side, hit), bin, w);
            }
            else
            {
                PathRec r = f < 0.5 ? ra : rb;
                AbsorbOpaqueBin(r.TermTile, r.TermSide, StripAt(r.TermTile, r.TermSide, r.Pts[^1]), bin, w);
            }
        }
    }

    readonly double[] _noPower = new double[Bins];

    void Terminal(PathRec r, double watts, int bin)
    {
        double arriving = watts * r.Remain;
        switch (r.Term)
        {
            case Term.Escape:
                AddEscaped(arriving);
                break;
            case Term.Opaque:
                AbsorbOpaqueBin(r.TermTile, r.TermSide, StripAt(r.TermTile, r.TermSide, r.Pts[^1]), bin, arriving);
                break;
            default:
                AddCulled(arriving);
                break;
        }
    }

    void FlushReflections(int bin)
    {
        foreach (var pool in _pool)
            if (pool != null && pool.Samples.Count > 0)
                EmitPool(pool, bin);
        _pool.Clear();
    }

    /// Traces a pool's reflected light as an ordinary ray tree (already counted as emitted)
    /// from its power-weighted median sample, then empties it.
    void EmitPool(ReflPool pool, int bin)
    {
        if (pool.Watts < _minRayW)
            AddCulled(pool.Watts);
        else
        {
            var sm = pool.Samples;
            double half = pool.Watts * 0.5, acc = 0;
            int m = 0;
            for (; m + PoolSample < sm.Count; m += PoolSample)
            {
                acc += sm[m];
                if (acc >= half)
                    break;
            }
            var p = new double[Bins];
            p[bin] = pool.Watts;
            var dir = new D2(sm[m + 3], sm[m + 4]);
            TraceTree(new D2(sm[m + 1], sm[m + 2]) + dir * Nudge, dir, p, pool.Medium, pool.Body);
        }
        pool.Watts = 0;
        pool.Samples.Clear();
    }
}

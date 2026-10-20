using System;
using System.Collections.Generic;
using Godot;

namespace SolarSim;

/// <summary>Results of a pass and how absorbed power is deposited into them.</summary>
public partial class LightEngine
{
    // ===========================================================================================
    // Results
    // ===========================================================================================

    /// <summary>Clears all results before a new pass.</summary>
    public void Begin()
    {
        Array.Clear(_tilePower);
        Array.Clear(_bandPower);
        foreach (int k in _stripIds)
            _strip[2 * k] = _strip[2 * k + 1] = 0f;
        _stripIds.Clear();
        _lit.Clear();
        _objAbsorbed.Clear();
        _objIncident.Clear();
        _segFrom.Clear();
        _segTo.Clear();
        _segPower.Clear();
        _render.Clear();
        _emitted = _absorbed = _escaped = _scattered = _culled = 0;
        _rayCount = 0;
        _tasks.Clear();
        _next = 0;
        _logs = new Dictionary<(int, int, int, int, int), TaskLog>();
        _replayed = _cacheHits = _cacheMisses = 0;
        _cache.Clear();
        _objects.Clear();
        if (_airDist.Length != _w * _h)
            BuildAccel();
    }

    public float[] TilePower() => (float[])_tilePower.Clone();
    public float[] BandPower() => (float[])_bandPower.Clone();
    /// <summary>
    /// Surface strips light reached (D18): index (tile * 4 + face) * strips + strip, faces 0 top,
    /// 1 bottom, 2 left, 3 right, strips along the face (+x for top/bottom, +y for left/right).
    /// </summary>
    public int[] StripIds() => _stripIds.ToArray();
    /// <summary>Watts arriving on each strip in StripIds.</summary>
    public float[] StripArriving() => Gather(0);
    /// <summary>Watts absorbed by each strip in StripIds (also counted in TilePower).</summary>
    public float[] StripAbsorbed() => Gather(1);
    public int[] LitTiles() => _lit.ToArray();
    public Vector2[] SegFrom() => _segFrom.ToArray();
    public Vector2[] SegTo() => _segTo.ToArray();
    public float[] SegPower() => _segPower.ToArray();
    public float[] Render() => _render.ToArray();
    public int RayCount() => _rayCount;

    public Godot.Collections.Dictionary ObjectAbsorbed()
    {
        var d = new Godot.Collections.Dictionary();
        foreach (var kv in _objAbsorbed)
            d[kv.Key] = kv.Value;
        return d;
    }

    public Godot.Collections.Dictionary ObjectIncident()
    {
        var d = new Godot.Collections.Dictionary();
        foreach (var kv in _objIncident)
        {
            var f = new float[2 * Bins];
            for (int k = 0; k < f.Length; k++)
                f[k] = (float)kv.Value[k];
            d[kv.Key] = f;
        }
        return d;
    }

    public Godot.Collections.Dictionary Stats() => new()
    {
        ["emitted"] = _emitted, ["absorbed"] = _absorbed, ["escaped"] = _escaped,
        ["scattered"] = _scattered, ["culled"] = _culled, ["rays"] = _rayCount,
        ["replayed"] = _replayed, ["cache_hits"] = _cacheHits, ["cache_misses"] = _cacheMisses,
        ["render_floats"] = _render.Count,
    };

    // ===========================================================================================
    // Deposits
    // ===========================================================================================

    /// <summary>
    /// Adds absorbed power in one bin: to object `body` when body >= 0 (it heats the object's
    /// own thermal node, D13), else to tile i.
    /// </summary>
    public void ApplyBin(int i, int bin, double watts, int body = -1)
    {
        if (watts <= 0)
            return;
        _absorbed += watts;
        if (body >= 0)
            _objAbsorbed[body] = (_objAbsorbed.TryGetValue(body, out double v) ? v : 0) + watts;
        else
        {
            if (_tilePower[i] == 0f)
                _lit.Add(i);
            _tilePower[i] += (float)watts;
            _bandPower[i * Bands + BandOf[bin]] += (float)watts;
        }
        if (_log != null)
        {
            _log.Deps.Add(i);
            _log.Deps.Add(bin);
            _log.Deps.Add(watts);
            _log.Deps.Add(body);
        }
    }

    /// Light of `watts` arriving on strip `strip` of face `side` of opaque tile i (side -1: no
    /// face, e.g. a ray that starts inside rock): recorded per strip (D18), absorbed by the
    /// surface, the rest scattered.
    void AbsorbOpaqueBin(int i, int side, int strip, int bin, double watts)
    {
        double a = watts * _surfAbs[_mat[i] * Bins + bin];
        LightStrip(i, side, strip, watts, a);
        ApplyBin(i, bin, a);
        AddScattered(watts - a);
    }

    void LightStrip(int i, int side, int strip, double arriving, double absorbed)
    {
        if (side < 0)
            return;
        AddStrip((i * 4 + side) * _strips + strip, (float)arriving, (float)absorbed);
    }

    /// A strip is listed when its arriving light first becomes nonzero; light too small for a
    /// float is dropped, so a strip is never listed twice.
    [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.AggressiveInlining)]
    void AddStrip(int index, float arriving, float absorbed)
    {
        if (arriving <= 0f)
            return;
        int j = 2 * index;
        if (_strip[j] == 0f)
            _stripIds.Add(index);
        _strip[j] += arriving;
        _strip[j + 1] += absorbed;
        if (_log != null)
        {
            if (s_task[j] == 0f)
                s_taskIds.Add(index);
            s_task[j] += arriving;
            s_task[j + 1] += absorbed;
        }
    }

    /// Which strip of face `side` of tile i the point p lies on.
    int StripAt(int i, int side, D2 p)
    {
        if (side < 0)
            return 0;
        double along = side <= 1 ? p.X / _tm - i % _w : p.Y / _tm - i / _w;
        return Math.Clamp((int)Math.Floor(along * _strips), 0, _strips - 1);
    }

    /// <summary>
    /// Adds light arriving on an object's active face (a probe, a cell's front): per bin, split by
    /// whether it came straight from the source (`direct`) or through optics first (refracted or
    /// reflected on the way). ObjectIncident gives 2 × Bins values: direct bins, then the rest.
    /// </summary>
    public void AddIncident(int owner, int bin, double watts, bool direct)
    {
        int slot = direct ? bin : Bins + bin;
        if (!_objIncident.TryGetValue(owner, out double[] acc))
            _objIncident[owner] = acc = new double[2 * Bins];
        acc[slot] += watts;
        if (_log != null)
        {
            _log.Incident.Add(owner);
            _log.Incident.Add(slot);
            _log.Incident.Add(watts);
        }
    }

    void AddEscaped(double w) { _escaped += w; if (_log != null) _log.Escaped += w; }
    void AddScattered(double w) { _scattered += w; if (_log != null) _log.Scattered += w; }
    void AddCulled(double w) { _culled += w; if (_log != null) _log.Culled += w; }

    /// Deposits into tile i. While recording a path, also keeps where the power was absorbed:
    /// a point (a == b) or a leg a→b of optical depth tau, so a cached copy placed at another
    /// offset from the tile grid can re-split it across the tiles it crosses there.
    void DepositBin(int i, int bin, double watts, int body, D2 a, D2 b, double tau = 0)
    {
        if (watts <= 0)
            return;
        if (_rec != null)
        {
            _rec.Deps.Add(i);
            _rec.Deps.Add(watts);
            _rec.Deps.Add(body);
            _rec.Deps.Add(a.X);
            _rec.Deps.Add(a.Y);
            _rec.Deps.Add(b.X);
            _rec.Deps.Add(b.Y);
            _rec.Deps.Add(tau);
        }
        else
            ApplyBin(i, bin, watts, body);
    }

    /// <summary>
    /// Stage 1 (direct light, after SetParallelSource or SetPointSource): every lane emits; lanes ending on an opaque face (kind == opaqueKind,
    /// refs = tile) deposit there, lanes that hit nothing (noneKind) escape. Consecutive lanes on
    /// the same surface strip are settled together.
    /// </summary>
    /// Lane k (u = U0 + (k + 0.5) LaneW, see the source) has its first hit at `depth[k]` along its
    /// ray. A lane covers its width over |perp · t| of a face with tangent t, spread over the
    /// strips it overlaps (lanes and strips differ in width; whole lanes per strip would alias),
    /// including those of the neighbouring tile's face where the surface continues there.
    public void DirectDeposit(byte[] kind, int[] refs, byte[] sides, float[] depth, int opaqueKind, int noneKind)
    {
        double total = 0;
        for (int b = 0; b < Bins; b++)
            total += _src.LaneWatts[b];
        _emitted += total * kind.Length;
        var lanes = new Dictionary<int, double>();   // Strip index (see StripIds) -> lanes landing
        var order = new List<int>();
        int none = 0;
        for (int k = 0; k < kind.Length; k++)
        {
            if (kind[k] == noneKind)
                none++;
            if (kind[k] != opaqueKind)
                continue;
            int t = refs[k], side = sides[k];
            double lu = _src.U0 + (k + 0.5) * _src.LaneW;
            D2 hit = _src.At(lu, depth[k]);
            D2 pv = _src.LanePerp(lu);
            bool horizontal = side <= 1;
            double along = horizontal ? hit.X / _tm - t % _w : hit.Y / _tm - t / _w;   // In tiles
            double half = 0.5 * _src.LaneWidthAt(depth[k]) / Math.Max(Math.Abs(horizontal ? pv.X : pv.Y), 1e-6) / _tm;
            if (half <= 1e-12)
            {
                AddLanes(lanes, order, (t * 4 + side) * _strips + StripAt(t, side, hit), 1.0);
                continue;
            }
            // The footprint over this tile's face and, where it spills over, the next tile's
            // along the same line (if that face is exposed too); weights over the kept parts.
            int step = horizontal ? 1 : _w;
            double kept = 0.0;
            for (int o = -1; o <= 1; o++)
            {
                int tile = t + o * step;
                double lo = Math.Max(along - half - o, 0.0), hi = Math.Min(along + half - o, 1.0);
                if (hi > lo && (o == 0 || ExposedFace(tile, side, t, o)))
                    kept += hi - lo;
            }
            for (int o = -1; o <= 1; o++)
            {
                int tile = t + o * step;
                double lo = Math.Max(along - half - o, 0.0), hi = Math.Min(along + half - o, 1.0);
                if (hi <= lo || (o != 0 && !ExposedFace(tile, side, t, o)))
                    continue;
                int baseIndex = (tile * 4 + side) * _strips;
                int s0 = Math.Max((int)Math.Floor(lo * _strips), 0), s1 = Math.Min((int)Math.Ceiling(hi * _strips), _strips);
                for (int st = s0; st < s1; st++)
                {
                    double overlap = Math.Min(hi, (st + 1.0) / _strips) - Math.Max(lo, (double)st / _strips);
                    if (overlap > 0.0)
                        AddLanes(lanes, order, baseIndex + st, overlap / kept);
                }
            }
        }
        int perFace = _strips, perTile = 4 * _strips;
        foreach (int f in order)
            AbsorbOpaqueSpectrum(f / perTile, f / perFace % 4, f % perFace, lanes[f]);
        _escaped += total * none;
    }

    /// Whether `tile`, `o` tiles from `from` along the line of face `side`, continues that face:
    /// in the same row (or column), opaque, with a transparent neighbour on that side.
    bool ExposedFace(int tile, int side, int from, int o)
    {
        bool horizontal = side <= 1;
        if (tile < 0 || tile >= _mat.Length || (horizontal && tile / _w != from / _w))
            return false;
        int nb = side == 0 ? tile - _w : (side == 1 ? tile + _w : (side == 2 ? tile - 1 : tile + 1));
        return _opaque[_mat[tile]] == 1 && nb >= 0 && nb < _mat.Length && _opaque[_mat[nb]] == 0;
    }

    static void AddLanes(Dictionary<int, double> lanes, List<int> order, int strip, double count)
    {
        if (lanes.TryGetValue(strip, out double v))
            lanes[strip] = v + count;
        else
        {
            lanes[strip] = count;
            order.Add(strip);
        }
    }

    void AbsorbOpaqueSpectrum(int i, int side, int strip, double lanes)
    {
        int m = _mat[i];
        double total = 0, absorbed = 0;
        for (int b = 0; b < Bins; b++)
        {
            double w = _src.LaneWatts[b] * lanes;
            double a = w * _surfAbs[m * Bins + b];
            _bandPower[i * Bands + BandOf[b]] += (float)a;
            absorbed += a;
            total += w;
        }
        if (absorbed > 0)
        {
            if (_tilePower[i] == 0f)
                _lit.Add(i);
            _tilePower[i] += (float)absorbed;
            _absorbed += absorbed;
        }
        LightStrip(i, side, strip, total, absorbed);
        AddScattered(total - absorbed);
    }
}

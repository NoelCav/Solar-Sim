using System;
using System.Collections.Generic;
using Godot;

namespace SolarSim;

/// <summary>
/// Compiled core of the light pass (design doc §6.4, §6.4.1): marching rays through tile media
/// and optical surfaces, the ray tree for secondary light, primary paths for beams, the beam
/// tracer (adaptive wavefronts, landing spreads, pooled reflections, render records), the
/// object cache, task logs for incremental passes, and the air distance field.
///
/// One engine per LightPass. GDScript (LightPass) builds the geometry (SurfaceSet, SunMap) and
/// orchestrates; it calls in once per pass setup and once per tick, never per ray.
/// Every watt emitted ends up in exactly one of: absorbed, escaped, scattered, culled.
/// </summary>
[GlobalClass]
public partial class LightEngine : RefCounted
{
    const int Bins = 6;
    const int Bands = 3;
    static readonly int[] BandOf = { 0, 1, 1, 1, 2, 2 };
    const double Eps = 1e-7;       // Minimum hit distance, m
    const double Nudge = 1e-5;     // Child rays start this far off the surface, m
    const double UEps = 1e-6;      // Along-segment tolerance for hits (watertight vertices)
    const int AirDistCap = 16;
    const int MaxRenderSegments = 60000;
    const double BaseSpacing = 0.1;   // Initial sample spacing across a run, m
    const double MinSpacing = 0.02;   // Narrowest interval worth refining, m
    const double LandingTol = 0.35;   // Same-path rays landing this close count as one beam
    const double ReplayDepsPerPath = 30.0;   // A replay costs ~one ray path per this many deposits
    const int CoatMirror = 1;
    const int CoatProbe = 2;
    const int AirId = 0;

    struct D2
    {
        public double X, Y;
        public D2(double x, double y) { X = x; Y = y; }
        public static D2 operator +(D2 a, D2 b) => new(a.X + b.X, a.Y + b.Y);
        public static D2 operator -(D2 a, D2 b) => new(a.X - b.X, a.Y - b.Y);
        public static D2 operator -(D2 a) => new(-a.X, -a.Y);
        public static D2 operator *(D2 a, double k) => new(a.X * k, a.Y * k);
        public double Dot(D2 b) => X * b.X + Y * b.Y;
        public D2 Normalized()
        {
            double l = Math.Sqrt(X * X + Y * Y);
            return l > 0 ? new D2(X / l, Y / l) : this;
        }
        public D2 Lerp(D2 b, double t) => new(X + (b.X - X) * t, Y + (b.Y - Y) * t);
        public double DistanceTo(D2 b) => Math.Sqrt((X - b.X) * (X - b.X) + (Y - b.Y) * (Y - b.Y));
        public bool IsZero => X == 0 && Y == 0;
        public Vector2 G => new((float)X, (float)Y);
        public static D2 From(Vector2 v) => new(v.X, v.Y);
    }

    struct R2
    {
        public double X0, Y0, X1, Y1;
        public R2(double x0, double y0, double x1, double y1) { X0 = x0; Y0 = y0; X1 = x1; Y1 = y1; }
        public bool Has(D2 p) => p.X >= X0 && p.Y >= Y0 && p.X < X1 && p.Y < Y1;
        public R2 Expand(D2 p) => new(Math.Min(X0, p.X), Math.Min(Y0, p.Y), Math.Max(X1, p.X), Math.Max(Y1, p.Y));
        public R2 Grow(double g) => new(X0 - g, Y0 - g, X1 + g, Y1 + g);
        public bool Intersects(R2 b) => X0 <= b.X1 && X1 >= b.X0 && Y0 <= b.Y1 && Y1 >= b.Y0;
    }

    enum Ev { Miss, Exit, StartOpaque, Opaque, Media, Surface }
    enum Term { Escape, Opaque, Culled, Pending }
    enum Span { Split, Exact, Near }

    /// Result of a primary path. Fractions are relative to the ray's unit input power.
    sealed class PathRec
    {
        public int Bin;
        public readonly List<D2> Pts = new();
        public readonly List<double> Frac = new();
        public readonly List<int> Sig = new();
        public Term Term;
        public int TermTile = -1, TermSide = -1;
        public double Remain = 1.0;
        public readonly List<double> Deps = new();    // (tile, fraction, body, ax, ay, bx, by, tau)…
        public readonly List<double> Probes = new();  // (owner, power)…
        public readonly List<double> Refls = new();   // (x, y, dx, dy, fraction, medium, body)…
        public D2 ContO, ContD;
        public int ContEvents;
    }

    /// Everything one beam task added to the results, plus the area its rays touched.
    sealed class TaskLog
    {
        public int K0, K1, Key, Bin;
        public double SMin;
        public List<double> Deps = new();     // (tile, bin, watts, body)…
        public readonly List<double> Probes = new();   // (owner, bin, watts)…
        public double Escaped, Scattered, Culled;
        public Vector2[] SegFrom = Array.Empty<Vector2>(), SegTo = Array.Empty<Vector2>();
        public float[] SegPower = Array.Empty<float>();
        public float[] Render = Array.Empty<float>();
        public R2 BBox;
        public int Paths;

        public void Compact()
        {
            var sums = new Dictionary<(int, int, int), double>();
            var order = new List<(int, int, int)>();
            for (int k = 0; k < Deps.Count; k += 4)
            {
                var key = ((int)Deps[k], (int)Deps[k + 1], (int)Deps[k + 3]);
                if (sums.TryGetValue(key, out double v))
                    sums[key] = v + Deps[k + 2];
                else
                {
                    sums[key] = Deps[k + 2];
                    order.Add(key);
                }
            }
            var outList = new List<double>(order.Count * 4);
            foreach (var key in order)
            {
                outList.Add(key.Item1);
                outList.Add(key.Item2);
                outList.Add(sums[key]);
                outList.Add(key.Item3);
            }
            Deps = outList;
        }
    }

    sealed class TreeRay
    {
        public D2 O, D;
        public double[] P;
        public int Medium, Body, Events;
    }

    sealed class ObjInfo
    {
        public int DefIdx, FirstPiece;
        public long AngleQ;
        public D2 Pos;
        public double Uc, S0;
    }

    struct Task
    {
        public int K0, K1, Key, Bin;
        public double SMin;
        public TaskLog Replay;
    }

    sealed class Interval
    {
        public double Ua, Ub;
        public PathRec Ra, Rb;
        public Span Kind;
        public List<(int tile, double w)> Spread;
    }

    // --- Settings and tables ---------------------------------------------------------------
    int _w, _h, _maxEvents;
    double _tm, _depth, _minChildW, _minRayW, _reflPool;
    byte[] _opaque = Array.Empty<byte>(), _dispersive = Array.Empty<byte>(), _hasBulk = Array.Empty<byte>();
    double[] _index = Array.Empty<double>(), _bulk = Array.Empty<double>(), _surfAbs = Array.Empty<double>();
    int[] _mat = Array.Empty<int>();

    // --- Surfaces ----------------------------------------------------------------------------
    int _segCount;
    double[] _ax = Array.Empty<double>(), _ay = Array.Empty<double>(), _ex = Array.Empty<double>(), _ey = Array.Empty<double>();
    D2[] _n = Array.Empty<D2>(), _na = Array.Empty<D2>(), _nb = Array.Empty<D2>();
    int[] _front = Array.Empty<int>(), _back = Array.Empty<int>(), _coating = Array.Empty<int>();
    int[] _owner = Array.Empty<int>(), _piece = Array.Empty<int>();
    double[] _refl = Array.Empty<double>();
    int[] _cellStart = Array.Empty<int>(), _cellItems = Array.Empty<int>();

    // --- Acceleration ------------------------------------------------------------------------
    byte[] _airDist = Array.Empty<byte>();
    readonly Dictionary<int, R2> _bounds = new();

    // --- Results of the current pass -----------------------------------------------------------
    float[] _tilePower = Array.Empty<float>();
    float[] _bandPower = Array.Empty<float>();
    readonly List<int> _lit = new();
    readonly Dictionary<int, double> _objAbsorbed = new();
    readonly Dictionary<int, double[]> _objIncident = new();
    readonly List<Vector2> _segFrom = new(), _segTo = new();
    readonly List<float> _segPower = new();
    readonly List<float> _render = new();
    double _emitted, _absorbed, _escaped, _scattered, _culled;
    int _rayCount;

    // --- Working state -------------------------------------------------------------------------
    readonly Stack<TreeRay> _stack = new();
    PathRec _rec;
    TaskLog _log;
    Ev _evKind;
    D2 _evO, _evFace;
    double _evT, _evU;
    int _evTile, _evMat, _evPrevMat, _evSeg, _evMedium, _evBody;

    // --- Beam pass state ---------------------------------------------------------------------
    readonly double[] _irr = new double[Bins];
    double _u0, _laneW;
    D2 _perp, _dir;
    readonly Dictionary<int, ObjInfo> _objects = new();
    readonly Dictionary<(int, long, int, long), PathRec> _cache = new();
    readonly List<Task> _tasks = new();
    int _next;
    Dictionary<(int, int, int, int), TaskLog> _logs = new();
    int _replayed, _cacheHits, _cacheMisses;

    /// Whether identical objects share traced sample paths (off = trace every path; tests).
    public static bool CacheEnabled = true;

    /// Sets CacheEnabled for every engine (callable from GDScript on any instance).
    public void SetCacheEnabled(bool on) => CacheEnabled = on;
    ObjInfo _runObj;
    int _runId;
    readonly List<Interval> _intervals = new();
    readonly List<ReflPool> _pool = new();   // Per reflection index along the path

    /// Reflected light of neighbouring samples gathered into one secondary ray. Boundaries sit
    /// on a fixed grid in u (not wherever sampling started), a sharp change of direction or
    /// medium starts a new pool (a different surface), and the ray emitted is the pool's
    /// power-weighted median sample, so it moves smoothly as the sun moves instead of jumping
    /// to whichever sample came last.
    sealed class ReflPool
    {
        public long Cell;
        public int Medium, Body;
        public double Watts;
        public readonly List<double> Samples = new();   // (watts, x, y, dx, dy)…
    }

    const double ReflSplitCos = 0.985;   // ~10°: a bigger turn between samples is another surface
    R2 _bbox;
    bool _bboxEmpty = true;

    // ===========================================================================================
    // Setup
    // ===========================================================================================

    /// <summary>Grid size, constants and per-material optical tables (BIN_COUNT values per material).</summary>
    public void Setup(int width, int height, double tileM, double depthM, int maxRayEvents, double minChildW,
        double minRayW, double reflPoolM, byte[] opaque, byte[] dispersive, byte[] hasBulk, float[] index,
        float[] bulk, float[] surfAbs)
    {
        _w = width;
        _h = height;
        _tm = tileM;
        _depth = depthM;
        _maxEvents = maxRayEvents;
        _minChildW = minChildW;
        _minRayW = minRayW;
        _reflPool = reflPoolM;
        _opaque = opaque;
        _dispersive = dispersive;
        _hasBulk = hasBulk;
        _index = ToDouble(index);
        _bulk = ToDouble(bulk);
        _surfAbs = ToDouble(surfAbs);
        _tilePower = new float[width * height];
        _bandPower = new float[width * height * Bands];
    }

    /// <summary>The optical surfaces this pass traces (from SurfaceSet).</summary>
    public void SetSurfaces(double[] ax, double[] ay, double[] ex, double[] ey, Vector2[] normal, Vector2[] normalA,
        Vector2[] normalB, int[] front, int[] back, int[] coating, int[] owner, int[] piece, float[] reflectance,
        int[] cellStart, int[] cellItems)
    {
        _segCount = ax.Length;
        _ax = ax; _ay = ay; _ex = ex; _ey = ey;
        _n = new D2[_segCount];
        _na = new D2[_segCount];
        _nb = new D2[_segCount];
        for (int s = 0; s < _segCount; s++)
        {
            _n[s] = D2.From(normal[s]);
            _na[s] = D2.From(normalA[s]);
            _nb[s] = D2.From(normalB[s]);
        }
        _front = front; _back = back; _coating = coating; _owner = owner; _piece = piece;
        _refl = ToDouble(reflectance);
        _cellStart = cellStart;
        _cellItems = cellItems;
        // A fixed point on each object (its first vertex) that its runs' samples are laid out
        // from, so the samples stay put on the object as the sun moves.
        _anchor.Clear();
        for (int s = 0; s < _segCount; s++)
            if (owner[s] >= 0 && !_anchor.ContainsKey(owner[s]))
                _anchor[owner[s]] = new D2(ax[s], ay[s]);
    }

    readonly Dictionary<int, D2> _anchor = new();

    /// <summary>Tile materials as of the pass start.</summary>
    public void SetMaterial(int[] material) => _mat = material;

    // ===========================================================================================
    // Acceleration: body bounds and the air distance field
    // ===========================================================================================

    /// <summary>Rebuilds body bounds and the whole distance field.</summary>
    public void BuildAccel()
    {
        RebuildBounds();
        _airDist = new byte[_w * _h];
        DistanceWindow(0, 0, _w, _h);
    }

    /// <summary>
    /// Updates acceleration after local edits: the distance field is recomputed only within
    /// AirDistCap tiles of the changed areas (x, y, w, h in meters) and of the old and new bounds
    /// of the changed objects; elsewhere distances can't have changed.
    /// </summary>
    public void UpdateAccel(float[] areas, int[] changedObjects)
    {
        if (_airDist.Length != _w * _h)
        {
            BuildAccel();
            return;
        }
        var windows = new List<R2>();
        for (int k = 0; k + 3 < areas.Length; k += 4)
            windows.Add(new R2(areas[k], areas[k + 1], areas[k] + areas[k + 2], areas[k + 1] + areas[k + 3]));
        foreach (int id in changedObjects)
            if (_bounds.TryGetValue(id, out R2 r))
                windows.Add(r);
        RebuildBounds();
        foreach (int id in changedObjects)
            if (_bounds.TryGetValue(id, out R2 r))
                windows.Add(r);
        int tiles = 0;
        var boxes = new List<(int, int, int, int)>();
        foreach (var r in windows)
        {
            int x0 = Math.Max(0, (int)Math.Floor(r.X0 / _tm) - AirDistCap);
            int y0 = Math.Max(0, (int)Math.Floor(r.Y0 / _tm) - AirDistCap);
            int x1 = Math.Min(_w, (int)Math.Floor(r.X1 / _tm) + AirDistCap + 1);
            int y1 = Math.Min(_h, (int)Math.Floor(r.Y1 / _tm) + AirDistCap + 1);
            if (x1 > x0 && y1 > y0)
            {
                boxes.Add((x0, y0, x1, y1));
                tiles += (x1 - x0) * (y1 - y0);
            }
        }
        if (tiles * 3 > _w * _h)
        {
            DistanceWindow(0, 0, _w, _h);
            return;
        }
        foreach (var b in boxes)
            DistanceWindow(b.Item1, b.Item2, b.Item3, b.Item4);
    }

    /// <summary>Bounds of an object's surfaces (grown slightly), or an empty rect.</summary>
    public Rect2 BodyBounds(int id)
    {
        if (!_bounds.TryGetValue(id, out R2 r))
            return new Rect2();
        return new Rect2((float)r.X0, (float)r.Y0, (float)(r.X1 - r.X0), (float)(r.Y1 - r.Y0));
    }

    /// <summary>The air distance field (tests).</summary>
    public byte[] AirDist() => (byte[])_airDist.Clone();

    void RebuildBounds()
    {
        _bounds.Clear();
        for (int s = 0; s < _segCount; s++)
        {
            int id = _owner[s];
            var a = new D2(_ax[s], _ay[s]);
            var b = new D2(_ax[s] + _ex[s], _ay[s] + _ey[s]);
            R2 r = _bounds.TryGetValue(id, out R2 old) ? old : new R2(a.X, a.Y, a.X, a.Y);
            _bounds[id] = r.Expand(a).Expand(b);
        }
        foreach (int id in new List<int>(_bounds.Keys))
            _bounds[id] = _bounds[id].Grow(1e-3);
    }

    /// Chessboard distance transform over tiles [x0, x1) × [y0, y1); tiles outside the window keep
    /// their values and act as boundary. Two passes with 8-neighbours.
    void DistanceWindow(int x0, int y0, int x1, int y1)
    {
        int w = _w, h = _h;
        byte[] df = _airDist;
        bool hasBuckets = _cellStart.Length == w * h + 1;
        bool airClear = _hasBulk[AirId] == 0;
        for (int y = y0; y < y1; y++)
            for (int x = x0; x < x1; x++)
            {
                int i = y * w + x;
                bool empty = airClear && _mat[i] == AirId && !(hasBuckets && _cellStart[i + 1] > _cellStart[i]);
                df[i] = (byte)(empty ? AirDistCap : 0);
            }
        for (int y = y0; y < y1; y++)
            for (int x = x0; x < x1; x++)
            {
                int i = y * w + x;
                int v = df[i];
                if (v == 0)
                    continue;
                if (x == 0 || y == 0 || x == w - 1)
                    v = 1;
                else
                    v = Math.Min(v, Math.Min(Math.Min(df[i - 1], df[i - w - 1]), Math.Min(df[i - w], df[i - w + 1])) + 1);
                df[i] = (byte)v;
            }
        for (int y = y1 - 1; y >= y0; y--)
            for (int x = x1 - 1; x >= x0; x--)
            {
                int i = y * w + x;
                int v = df[i];
                if (v <= 1)
                    continue;
                if (y == h - 1)
                    v = 1;
                else
                    v = Math.Min(v, Math.Min(Math.Min(df[i + 1], df[i + w + 1]), Math.Min(df[i + w], df[i + w - 1])) + 1);
                df[i] = (byte)v;
            }
    }

    // ===========================================================================================
    // Results
    // ===========================================================================================

    /// <summary>Clears all results before a new pass.</summary>
    public void Begin()
    {
        Array.Clear(_tilePower);
        Array.Clear(_bandPower);
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
        _logs = new Dictionary<(int, int, int, int), TaskLog>();
        _replayed = _cacheHits = _cacheMisses = 0;
        _cache.Clear();
        _objects.Clear();
        if (_airDist.Length != _w * _h)
            BuildAccel();
    }

    public float[] TilePower() => (float[])_tilePower.Clone();
    public float[] BandPower() => (float[])_bandPower.Clone();
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
            var f = new float[Bins];
            for (int b = 0; b < Bins; b++)
                f[b] = (float)kv.Value[b];
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

    void AbsorbOpaqueBin(int i, int bin, double watts)
    {
        double a = watts * _surfAbs[_mat[i] * Bins + bin];
        ApplyBin(i, bin, a);
        AddScattered(watts - a);
    }

    /// <summary>Adds a probe reading.</summary>
    public void AddProbe(int owner, int bin, double watts)
    {
        if (!_objIncident.TryGetValue(owner, out double[] acc))
            _objIncident[owner] = acc = new double[Bins];
        acc[bin] += watts;
        if (_log != null)
        {
            _log.Probes.Add(owner);
            _log.Probes.Add(bin);
            _log.Probes.Add(watts);
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
    /// Stage 1 (direct light): every lane emits; lanes ending on an opaque face (kind == opaqueKind,
    /// refs = tile) deposit there, lanes that hit nothing (noneKind) escape. Consecutive lanes on
    /// the same tile are settled together.
    /// </summary>
    public void DirectDeposit(byte[] kind, int[] refs, float[] spectrum, double laneArea, int opaqueKind, int noneKind)
    {
        double total = 0;
        for (int b = 0; b < Bins; b++)
            total += spectrum[b];
        _emitted += total * laneArea * kind.Length;
        int runTile = -1, runLanes = 0, none = 0;
        for (int k = 0; k < kind.Length; k++)
        {
            int t = kind[k] == opaqueKind ? refs[k] : -1;
            if (t != runTile)
            {
                if (runTile >= 0)
                    AbsorbOpaqueSpectrum(runTile, spectrum, runLanes * laneArea);
                runTile = t;
                runLanes = 0;
            }
            runLanes++;
            if (kind[k] == noneKind)
                none++;
        }
        if (runTile >= 0)
            AbsorbOpaqueSpectrum(runTile, spectrum, runLanes * laneArea);
        _escaped += total * laneArea * none;
    }

    void AbsorbOpaqueSpectrum(int i, float[] spectrum, double scale)
    {
        int m = _mat[i];
        double total = 0, absorbed = 0;
        for (int b = 0; b < Bins; b++)
        {
            double w = spectrum[b] * scale;
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
        AddScattered(total - absorbed);
    }

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
                AbsorbOpaque(_evTile, p);
                break;
            case Ev.Opaque:
                Emit(start, hit, p0);
                AbsorbOpaque(_evTile, p);
                break;
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

    void AbsorbOpaque(int i, double[] p)
    {
        for (int b = 0; b < Bins; b++)
            if (p[b] > 0)
                AbsorbOpaqueBin(i, b, p[b]);
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
                    AddProbe(owner, b, p[b]);
                Push(hit + d * Nudge, d, p, medium, body, events + 1);
                break;
            case CoatMirror:
            {
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
                    rec.TermSide = FaceCode(_evFace);
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
                        rec.Probes.Add(owner);
                        rec.Probes.Add(p[bin]);
                        o = hit + d * Nudge;
                        continue;
                    }
                    rec.Sig.Add(_piece[s] * 2 + (fromFront ? 0 : 1));
                    if (_coating[s] == CoatMirror)
                    {
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
        for (int b = 0; b < Bins; b++)
            _irr[b] = irradiance[b];
        _u0 = u0;
        _laneW = laneW;
        _perp = D2.From(perp);
        _dir = D2.From(dir);
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
        for (int k = 0; k + 3 < areas.Length; k += 4)
            changed.Add(new R2(areas[k], areas[k + 1], areas[k] + areas[k + 2], areas[k + 1] + areas[k + 3]));
        _tasks.Clear();
        _next = 0;
        for (int r = 0; r * 3 + 2 < runs.Length; r++)
        {
            int k0 = runs[r * 3], k1 = runs[r * 3 + 1], key = runs[r * 3 + 2];
            for (int b = 0; b < Bins; b++)
            {
                if (_irr[b] <= 0)
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
                replayWork += (log.Deps.Count / 4) / ReplayDepsPerPath;
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
        for (int k = 0; k < deps.Count; k += 4)
            ApplyBin((int)deps[k], (int)deps[k + 1], deps[k + 2], (int)deps[k + 3]);
        var probes = t.Probes;
        for (int k = 0; k < probes.Count; k += 3)
            AddProbe((int)probes[k], (int)probes[k + 1], probes[k + 2]);
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
        double irr = _irr[bin];
        if (irr <= 0)
            return null;
        var log = new TaskLog { K0 = task.K0, K1 = task.K1, Key = task.Key, Bin = bin, SMin = task.SMin };
        _log = log;
        int paths0 = _rayCount;
        int seg0 = _segFrom.Count;
        int render0 = _render.Count;
        _bboxEmpty = true;
        double uLo = _u0 + task.K0 * _laneW;
        double uHi = _u0 + (task.K1 + 1) * _laneW;
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
            uc = anchor.Dot(_perp);
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
            Settle(iv, irr, bin);
        FlushReflections(bin);
        _intervals.Clear();
        _log = null;
        log.Compact();
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
        if (rec.Probes.Count > 0)
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

    void Refine(double ua, PathRec ra, double ub, PathRec rb, double s0, int bin)
    {
        Span kind = Classify(ra, rb, out var spread);
        if (kind != Span.Split)
        {
            _intervals.Add(new Interval { Ua = ua, Ra = ra, Ub = ub, Rb = rb, Kind = kind, Spread = spread });
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
    Span Classify(PathRec ra, PathRec rb, out List<(int, double)> spread)
    {
        spread = null;
        if (ra.Term != rb.Term || ra.Term == Term.Culled)
            return Span.Split;
        if (ra.Pts.Count != rb.Pts.Count || !SameSig(ra, rb))
            return Span.Split;
        if (ra.Term != Term.Opaque)
            return Span.Exact;
        spread = Spread(ra, rb);
        if (spread != null)
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

    /// Tiles (and weights) a coherent beam lands on between the two rays' end points: the same
    /// tile, or a straight run of exposed faces of the same orientation; null otherwise.
    List<(int, double)> Spread(PathRec ra, PathRec rb)
    {
        int ta = ra.TermTile, tb = rb.TermTile;
        if (ta == tb)
            return new List<(int, double)> { (ta, 1.0) };
        int code = ra.TermSide;
        if (code != rb.TermSide || code < 0)
            return null;
        int w = _w;
        D2 pa = ra.Pts[^1], pb = rb.Pts[^1];
        bool horizontal = code <= 1;
        int line = horizontal ? ta / w : ta % w;
        if (line != (horizontal ? tb / w : tb % w))
            return null;
        int c0 = horizontal ? Math.Min(ta % w, tb % w) : Math.Min(ta / w, tb / w);
        int c1 = horizontal ? Math.Max(ta % w, tb % w) : Math.Max(ta / w, tb / w);
        double lo = horizontal ? Math.Min(pa.X, pb.X) : Math.Min(pa.Y, pb.Y);
        double hi = horizontal ? Math.Max(pa.X, pb.X) : Math.Max(pa.Y, pb.Y);
        double length = hi - lo;
        var outList = new List<(int, double)>();
        for (int c = c0; c <= c1; c++)
        {
            int t = horizontal ? line * w + c : c * w + line;
            // The face must be exposed: an opaque tile with a transparent neighbour on that side.
            int nb = code == 0 ? t - w : (code == 1 ? t + w : (code == 2 ? t - 1 : t + 1));
            if (_opaque[_mat[t]] == 0 || (nb >= 0 && nb < _mat.Length && _opaque[_mat[nb]] == 1))
                return null;
            double overlap = Math.Min(hi, (c + 1) * _tm) - Math.Max(lo, c * _tm);
            outList.Add((t, length > 1e-9 ? overlap / length : 1.0 / (c1 - c0 + 1)));
        }
        return outList;
    }

    void Settle(Interval iv, double irr, int bin)
    {
        PathRec ra = iv.Ra, rb = iv.Rb;
        double half = irr * (iv.Ub - iv.Ua) * _depth * 0.5;   // W each ray carries for this interval
        foreach (var p in ra.Pts)
            Grow(p);
        foreach (var p in rb.Pts)
            Grow(p);
        ApplyPath(ra, half, bin, iv.Ua);
        ApplyPath(rb, half, bin, iv.Ub);
        switch (iv.Kind)
        {
            case Span.Exact:
            {
                double arriving = half * (ra.Remain + rb.Remain);
                if (ra.Term == Term.Escape)
                    AddEscaped(arriving);
                else
                    foreach (var (tile, wgt) in iv.Spread)
                        AbsorbOpaqueBin(tile, bin, arriving * wgt);
                RenderStrip(ra, rb, half * 2.0, bin);
                break;
            }
            case Span.Near:
                Terminal(ra, half, bin);
                Terminal(rb, half, bin);
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
        D2 d = b - a;
        double len = Math.Sqrt(d.X * d.X + d.Y * d.Y);
        if (len < 1e-12)
        {
            AddDep(r, TileAt(a), frac, body, a, a, 0);
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
            AddDep(r, TileAt(a + d * (0.5 * (t0 + t1))), frac * w, body, p0, p1, tau * (t1 - t0));
        }
    }

    readonly List<double> _splitTs = new();

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
    void ApplyPath(PathRec r, double watts, int bin, double u)
    {
        var deps = r.Deps;
        for (int k = 0; k < deps.Count; k += 8)
            ApplyBin((int)deps[k], bin, watts * deps[k + 1], (int)deps[k + 2]);
        var probes = r.Probes;
        for (int k = 0; k < probes.Count; k += 2)
            AddProbe((int)probes[k], bin, watts * probes[k + 1]);
        var refls = r.Refls;
        for (int k = 0, idx = 0; k < refls.Count; k += 7, idx++)
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
                int last = pool.Samples.Count - 5;
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

    void Terminal(PathRec r, double watts, int bin)
    {
        double arriving = watts * r.Remain;
        switch (r.Term)
        {
            case Term.Escape:
                AddEscaped(arriving);
                break;
            case Term.Opaque:
                AbsorbOpaqueBin(r.TermTile, bin, arriving);
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
            for (; m + 5 < sm.Count; m += 5)
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

    // --- Render records (layout in BeamGeometry) ---------------------------------------------

    /// A coherent beam between two rays, drawn up to (not including) leg `last` (-1 = all).
    void RenderStrip(PathRec ra, PathRec rb, double watts, int bin, int last = -1)
    {
        int end = last < 0 ? ra.Pts.Count - 1 : last;
        if (end < 2)
            return;
        _render.Add(0);   // BeamGeometry.STRIP
        _render.Add(bin);
        _render.Add((float)watts);
        _render.Add(end);   // points 1..end
        for (int k = 1; k <= end; k++)
        {
            D2 a = ra.Pts[k], b = rb.Pts[k];
            _render.Add((float)a.X);
            _render.Add((float)a.Y);
            _render.Add((float)b.X);
            _render.Add((float)b.Y);
            _render.Add((float)ra.Frac[k]);
            _render.Add((float)rb.Frac[k]);
        }
    }

    /// Two rays of an unresolved split. They stay one beam over the events they share and
    /// along the next leg up to where the nearer of them stops (a lens edge one ray clips and
    /// the other passes): drawn as slivers there, each half as wide as the interval and centered
    /// on its ray, they would overlap the neighbouring beams and leave a gap between them,
    /// showing as bright and dark lines along the whole path. Slivers start where they part.
    void RenderSplit(PathRec ra, PathRec rb, double watts, double width, int bin)
    {
        int shared = 0;
        while (shared < ra.Sig.Count && shared < rb.Sig.Count && ra.Sig[shared] == rb.Sig[shared])
            shared++;
        if (shared == 0 || shared + 1 >= ra.Pts.Count || shared + 1 >= rb.Pts.Count)
        {
            // Parted at the first event (whose incoming sunlight is the sheet's) or one ray
            // ends there: nothing in common to draw as a beam.
            RenderStrip(ra, rb, watts * 2.0, bin, shared);
            RenderRay(ra, watts, width, bin, Math.Max(shared, 1));
            RenderRay(rb, watts, width, bin, Math.Max(shared, 1));
            return;
        }
        // Points 1..shared follow the same events; cut the next leg at the nearer stop.
        D2 a0 = ra.Pts[shared], b0 = rb.Pts[shared];
        double la = a0.DistanceTo(ra.Pts[shared + 1]), lb = b0.DistanceTo(rb.Pts[shared + 1]);
        double t = Math.Min(la, lb);
        D2 aCut = la > 1e-12 ? a0.Lerp(ra.Pts[shared + 1], t / la) : a0;
        D2 bCut = lb > 1e-12 ? b0.Lerp(rb.Pts[shared + 1], t / lb) : b0;
        double fa = la > 1e-12 ? ra.Frac[shared] + (ra.Frac[shared + 1] - ra.Frac[shared]) * t / la : ra.Frac[shared];
        double fb = lb > 1e-12 ? rb.Frac[shared] + (rb.Frac[shared + 1] - rb.Frac[shared]) * t / lb : rb.Frac[shared];

        _render.Add(0);   // BeamGeometry.STRIP
        _render.Add(bin);
        _render.Add((float)(watts * 2.0));
        _render.Add(shared + 1);   // points 1..shared, then the cut
        for (int k = 1; k <= shared; k++)
            AddStripPoint(ra.Pts[k], rb.Pts[k], ra.Frac[k], rb.Frac[k]);
        AddStripPoint(aCut, bCut, fa, fb);

        RenderRay(ra, watts, width, bin, shared + 1, aCut, fa);
        RenderRay(rb, watts, width, bin, shared + 1, bCut, fb);
    }

    void AddStripPoint(D2 a, D2 b, double fa, double fb)
    {
        _render.Add((float)a.X);
        _render.Add((float)a.Y);
        _render.Add((float)b.X);
        _render.Add((float)b.Y);
        _render.Add((float)fa);
        _render.Add((float)fb);
    }

    /// A lone ray drawn as a beam of fixed width from leg `first` on (incoherent slivers).
    void RenderRay(PathRec r, double watts, double width, int bin, int first = 1)
    {
        int n = r.Pts.Count - first;
        if (n < 2)
            return;
        _render.Add(1);   // BeamGeometry.SLIVER
        _render.Add(bin);
        _render.Add((float)watts);
        _render.Add(n);
        _render.Add((float)width);
        for (int k = first; k < r.Pts.Count; k++)
        {
            D2 a = r.Pts[k];
            _render.Add((float)a.X);
            _render.Add((float)a.Y);
            _render.Add((float)r.Frac[k]);
        }
    }

    /// A lone ray drawn from `start` (fraction `frac`), then through its points from `next` on.
    void RenderRay(PathRec r, double watts, double width, int bin, int next, D2 start, double frac)
    {
        int n = r.Pts.Count - next + 1;
        if (n < 2 || start.DistanceTo(r.Pts[^1]) < 1e-9)
            return;
        _render.Add(1);   // BeamGeometry.SLIVER
        _render.Add(bin);
        _render.Add((float)watts);
        _render.Add(n);
        _render.Add((float)width);
        _render.Add((float)start.X);
        _render.Add((float)start.Y);
        _render.Add((float)frac);
        for (int k = next; k < r.Pts.Count; k++)
        {
            D2 a = r.Pts[k];
            _render.Add((float)a.X);
            _render.Add((float)a.Y);
            _render.Add((float)r.Frac[k]);
        }
    }

    // --- Helpers ------------------------------------------------------------------------------

    static double Sum(double[] p)
    {
        double t = 0;
        foreach (double v in p)
            t += v;
        return t;
    }

    static int NonzeroBins(double[] p)
    {
        int c = 0;
        foreach (double v in p)
            if (v > 0)
                c++;
        return c;
    }

    static double[] ToDouble(float[] a)
    {
        var d = new double[a.Length];
        for (int i = 0; i < a.Length; i++)
            d[i] = a[i];
        return d;
    }
}

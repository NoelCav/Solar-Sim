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
    const double MinSpacing = 0.02;   // Narrowest interval worth refining, m
    const double LandingTol = 0.35;   // Same-path rays landing this close count as one beam
    // Flat record layouts (lists of doubles): the number of values per entry.
    const int PathDep = 8;      // PathRec.Deps: tile, fraction, body, ax, ay, bx, by, tau
    const int PathRefl = 7;     // PathRec.Refls: x, y, dx, dy, fraction, medium, body
    const int PathIncident = 3; // PathRec.Incident and TaskLog.Incident: owner, power or slot, direct or watts
    const int LogDep = 4;       // TaskLog.Deps: tile, bin, watts, body
    const int LogStrip = 3;     // TaskLog.Strips: strip index, watts arriving, watts absorbed
    const int PoolSample = 5;   // ReflPool.Samples: watts, x, y, dx, dy
    const int AreaRect = 4;     // Areas passed in from GDScript: x, y, w, h
    const double ReplayDepsPerPath = 30.0;   // A replay costs ~one ray path per this many deposits
    const double SpreadStep = 0.01;  // Medium deposits of a coherent interval are spread in steps this wide, m
    const int CoatMirror = 1;
    const int CoatProbe = 2;
    const int CoatCell = 3;   // A mirror whose front face also records the light arriving on it
    const int CoatSplit = 4;  // A thin plate that reflects a share per bin and passes the rest (beam splitter, dichroic)
    const int MaxForks = 5;   // Splitters a path forks at at most: 2^5 variants of a run
    const int SplitSig = 2000003;   // Marks the reflected branch in a path's signature
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
        public readonly List<double> Incident = new();  // (owner, power, 1 direct / 0 through optics)…
        public readonly List<double> Refls = new();   // (x, y, dx, dy, fraction, medium, body)…
        public D2 ContO, ContD;
        public int ContEvents;
        public int Forks;         // Splitters the path has met
        public int Start;         // Index in Pts where this variant's own record begins (earlier is the parent's)
        public bool Invalid;      // The variant asks for a splitter this ray never met: it carries nothing
    }

    /// Everything one beam task added to the results, plus the area its rays touched.
    sealed class TaskLog
    {
        public int K0, K1, Key, Bin, Mask, Forks;
        public double SMin;
        public List<double> Deps = new();     // (tile, bin, watts, body)…
        public readonly List<double> Strips = new();   // (strip index, watts arriving, watts absorbed)…
        public readonly List<double> Incident = new();   // (owner, slot, watts)… slot as in AddIncident
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
            for (int k = 0; k < Deps.Count; k += LogDep)
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
        public int K0, K1, Key, Bin, Mask;
        public double SMin;
        public TaskLog Replay;
    }

    sealed class Interval
    {
        public double Ua, Ub;
        public PathRec Ra, Rb;
        public Span Kind;
    }

    // --- Settings and tables ---------------------------------------------------------------
    int _w, _h, _maxEvents, _strips = 1;
    double _baseSpacing;   // Initial sample spacing across a beam, m (a point source's: at 1 m)
    double _tm, _depth, _minChildW, _minRayW, _reflPool;
    double _baseChildW, _baseRayW;   // Cull thresholds for full sunlight (SetCullScale)
    byte[] _opaque = Array.Empty<byte>(), _dispersive = Array.Empty<byte>(), _hasBulk = Array.Empty<byte>();
    double[] _index = Array.Empty<double>(), _bulk = Array.Empty<double>(), _surfAbs = Array.Empty<double>();
    int[] _mat = Array.Empty<int>();

    // --- Surfaces ----------------------------------------------------------------------------
    int _segCount;
    double[] _ax = Array.Empty<double>(), _ay = Array.Empty<double>(), _ex = Array.Empty<double>(), _ey = Array.Empty<double>();
    D2[] _n = Array.Empty<D2>(), _na = Array.Empty<D2>(), _nb = Array.Empty<D2>();
    int[] _front = Array.Empty<int>(), _back = Array.Empty<int>(), _coating = Array.Empty<int>();
    int[] _owner = Array.Empty<int>(), _piece = Array.Empty<int>();
    double[] _refl = Array.Empty<double>(), _trans = Array.Empty<double>();
    int[] _cellStart = Array.Empty<int>(), _cellItems = Array.Empty<int>();

    // --- Acceleration ------------------------------------------------------------------------
    byte[] _airDist = Array.Empty<byte>();
    readonly Dictionary<int, R2> _bounds = new();

    // --- Results of the current pass -----------------------------------------------------------
    float[] _tilePower = Array.Empty<float>();
    float[] _bandPower = Array.Empty<float>();
    // Light per surface strip (D18): strip index (tile * 4 + face) * strips + strip -> slot.
    // Dense by strip index, like _tilePower: [2k] watts arriving, [2k + 1] absorbed; the touched
    // strips listed for publishing.
    float[] _strip = Array.Empty<float>();
    readonly List<int> _stripIds = new();
    // What the beam task being logged added per strip (one task runs at a time: shared scratch).
    static float[] s_task = Array.Empty<float>();
    static readonly List<int> s_taskIds = new();
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
    readonly Dictionary<int, ObjInfo> _objects = new();
    readonly Dictionary<(int, long, int, long), PathRec> _cache = new();
    readonly List<Task> _tasks = new();
    int _next;
    Dictionary<(int, int, int, int, int), TaskLog> _logs = new();
    int _mask, _runForks;   // The splitter branches the run being traced takes (bit j: reflect at the j-th), and the most it met
    LightEngine _prevEngine;   // The last pass, for replaying tasks
    bool _reuseLogs;
    List<R2> _changedAreas = new();
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

    /// Arriving (0) or absorbed (1) watts at the touched strips, in StripIds order.
    float[] Gather(int which)
    {
        var f = new float[_stripIds.Count];
        for (int k = 0; k < f.Length; k++)
            f[k] = _strip[2 * _stripIds[k] + which];
        return f;
    }

    static double[] ToDouble(float[] a)
    {
        var d = new double[a.Length];
        for (int i = 0; i < a.Length; i++)
            d[i] = a[i];
        return d;
    }
}
using System;
using System.Collections.Generic;
using Godot;

namespace SolarSim;

/// <summary>Setup: grid size, material and surface tables, and the acceleration structures (body bounds, air distance field).</summary>
public partial class LightEngine
{
    // ===========================================================================================
    // Setup
    // ===========================================================================================

    /// <summary>Grid size, constants and per-material optical tables (BIN_COUNT values per material).</summary>
    public void Setup(int width, int height, double tileM, double depthM, int maxRayEvents, double minChildW,
        double minRayW, double reflPoolM, double beamSpacingM, byte[] opaque, byte[] dispersive, byte[] hasBulk, float[] index,
        float[] bulk, float[] surfAbs, int skinStrips)
    {
        _strips = skinStrips;
        _w = width;
        _h = height;
        _tm = tileM;
        _depth = depthM;
        _maxEvents = maxRayEvents;
        _minChildW = _baseChildW = minChildW;
        _minRayW = _baseRayW = minRayW;
        _reflPool = reflPoolM;
        _baseSpacing = beamSpacingM;
        _opaque = opaque;
        _dispersive = dispersive;
        _hasBulk = hasBulk;
        _index = ToDouble(index);
        _bulk = ToDouble(bulk);
        _surfAbs = ToDouble(surfAbs);
        _tilePower = new float[width * height];
        _strip = new float[width * height * 4 * skinStrips * 2];
        if (s_task.Length < _strip.Length)
            s_task = new float[_strip.Length];
        _bandPower = new float[width * height * Bands];
    }

    /// <summary>
    /// Scales the cull thresholds to the light being traced (k = its DNI relative to full
    /// sunlight), so dim light (moonlight, ~10⁻⁶ of the sun) keeps the same relative detail.
    /// </summary>
    public void SetCullScale(double k)
    {
        _minChildW = _baseChildW * k;
        _minRayW = _baseRayW * k;
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
        for (int k = 0; k + AreaRect - 1 < areas.Length; k += AreaRect)
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
}

using System;
using System.Collections.Generic;
using Godot;

namespace SolarSim;

/// <summary>
/// Compiled builder for BeamGeometry: turns beam render records (LightEngine.Render()) into
/// colored triangles. Irradiance goes as 1/width, so each leg is cut into slices packed toward
/// the point where the two rays cross (a focus), and brightness is evaluated per slice. Only
/// bins with a non-zero color are built. Record layout in BeamGeometry.
/// </summary>
[GlobalClass]
public partial class BeamMesh : RefCounted
{
    const int Bins = 6;
    static readonly double[] CrossSteps = { 0.5, 0.25, 0.1, 0.03 };

    double _sunLevel, _logGain, _minWidth;
    readonly List<Vector2> _verts = new();
    readonly List<Color> _cols = new();

    /// <summary>
    /// Builds triangles for every record in buf. rgb holds 3 floats per bin (color per unit of
    /// tone, zero = hidden), share the AM1.5 share per bin. Returns [verts, colors].
    /// </summary>
    public Godot.Collections.Array Build(float[] buf, float[] rgb, float[] share, double referenceDni, double px,
        double vertexScale, double depthM, double sunLevel, double logGain, double minWidthM)
    {
        _sunLevel = sunLevel;
        _logGain = logGain;
        _minWidth = minWidthM;
        _verts.Clear();
        _cols.Clear();
        int o = 0;
        while (o < buf.Length)
        {
            int kind = (int)buf[o];
            int bin = (int)buf[o + 1];
            double watts = buf[o + 2];
            int n = (int)buf[o + 3];
            bool shown = rgb[bin * 3] != 0f || rgb[bin * 3 + 1] != 0f || rgb[bin * 3 + 2] != 0f;
            var col = new Vector3(rgb[bin * 3], rgb[bin * 3 + 1], rgb[bin * 3 + 2]) / (float)vertexScale;
            double reference = referenceDni * share[bin];
            if (kind == 0)
            {
                o += 4;
                if (shown)
                    Strip(buf, o, n, watts, col, reference, px, depthM);
                o += n * 6;
            }
            else
            {
                double width = buf[o + 4];
                o += 5;
                if (shown)
                    Sliver(buf, o, n, watts, width, col, reference, px, depthM);
                o += n * 3;
            }
        }
        return new Godot.Collections.Array { _verts.ToArray(), _cols.ToArray() };
    }

    double Tone(double c) => c <= 1.0 ? _sunLevel * c : _sunLevel * (1.0 + _logGain * Math.Log(c));

    static Color ColorOf(Vector3 rgb, double level) =>
        new((float)(rgb.X * level), (float)(rgb.Y * level), (float)(rgb.Z * level), 1f);

    void Strip(float[] buf, int o, int n, double watts, Vector3 rgb, double reference, double px, double depth)
    {
        var ts = new List<double>(16);
        for (int k = 0; k < n - 1; k++)
        {
            int q = o + k * 6;
            double a0x = buf[q], a0y = buf[q + 1], b0x = buf[q + 2], b0y = buf[q + 3];
            double a1x = buf[q + 6], a1y = buf[q + 7], b1x = buf[q + 8], b1y = buf[q + 9];
            double lx = a1x - a0x, ly = a1y - a0y;
            double ll = Math.Sqrt(lx * lx + ly * ly);
            if (ll > 0) { lx /= ll; ly /= ll; }
            // Concentration per meter of width: divide by the local width to get C.
            double p = watts * 0.5 * (buf[q + 4] + buf[q + 5]) / (depth * reference);
            // Signed width along the leg is linear in t; a sign change is the crossing.
            double w0 = lx * (b0y - a0y) - ly * (b0x - a0x);
            double w1 = lx * (b1y - a1y) - ly * (b1x - a1x);
            ts.Clear();
            ts.Add(0.0);
            double tCross = -1.0;
            if (w0 * w1 < 0.0)
            {
                tCross = w0 / (w0 - w1);
                double reach = Math.Max(tCross, 1.0 - tCross);
                ts.Add(tCross);
                foreach (double d in CrossSteps)
                {
                    double span = d * reach;
                    if (tCross - span > 0.0)
                        ts.Add(tCross - span);
                    if (tCross + span < 1.0)
                        ts.Add(tCross + span);
                }
                ts.Add(1.0);
                ts.Sort();
            }
            else
            {
                // Slices grow with how strongly the leg converges or diverges.
                double ratio = Math.Max(Math.Abs(w0), Math.Abs(w1)) / Math.Max(Math.Min(Math.Abs(w0), Math.Abs(w1)), _minWidth);
                int m = Math.Clamp((int)Math.Ceiling(Math.Log(ratio) / Math.Log(2.0)) + 1, 1, 6);
                for (int j = 1; j <= m; j++)
                    ts.Add((double)j / m);
            }
            var prevA = new Vector2((float)(a0x * px), (float)(a0y * px));
            var prevB = new Vector2((float)(b0x * px), (float)(b0y * px));
            Color prevC = ColorOf(rgb, Tone(p / Math.Max(Math.Abs(w0), _minWidth)));
            for (int j = 1; j < ts.Count; j++)
            {
                double t = ts[j];
                var pa = new Vector2((float)((a0x + (a1x - a0x) * t) * px), (float)((a0y + (a1y - a0y) * t) * px));
                var pb = new Vector2((float)((b0x + (b1x - b0x) * t) * px), (float)((b0y + (b1y - b0y) * t) * px));
                Color c = ColorOf(rgb, Tone(p / Math.Max(Math.Abs(w0 + (w1 - w0) * t), _minWidth)));
                if (ts[j - 1] == tCross)
                    Tri(prevA, pa, pb, prevC, c, c);
                else if (t == tCross)
                    Tri(prevA, pa, prevB, prevC, c, prevC);
                else
                {
                    Tri(prevA, pa, pb, prevC, c, c);
                    Tri(prevA, pb, prevB, prevC, c, prevC);
                }
                prevA = pa;
                prevB = pb;
                prevC = c;
            }
        }
    }

    void Sliver(float[] buf, int o, int n, double watts, double width, Vector3 rgb, double reference, double px,
        double depth)
    {
        for (int k = 0; k < n - 1; k++)
        {
            int q = o + k * 3;
            var a = new Vector2((float)(buf[q] * px), (float)(buf[q + 1] * px));
            var b = new Vector2((float)(buf[q + 3] * px), (float)(buf[q + 4] * px));
            Vector2 side = (b - a).Normalized().Orthogonal() * (float)(width * 0.5 * px);
            Color c = ColorOf(rgb, Tone(watts * buf[q + 2] / (Math.Max(width, _minWidth) * depth * reference)));
            Tri(a - side, b - side, b + side, c, c, c);
            Tri(a - side, b + side, a + side, c, c, c);
        }
    }

    void Tri(Vector2 a, Vector2 b, Vector2 c, Color ca, Color cb, Color cc)
    {
        _verts.Add(a);
        _verts.Add(b);
        _verts.Add(c);
        _cols.Add(ca);
        _cols.Add(cb);
        _cols.Add(cc);
    }
}

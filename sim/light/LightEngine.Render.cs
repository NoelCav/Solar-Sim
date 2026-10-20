using System;
using System.Collections.Generic;
using Godot;

namespace SolarSim;

/// <summary>Render records for the beam mesh (layout in BeamGeometry).</summary>
public partial class LightEngine
{
    // --- Render records (layout in BeamGeometry) ---------------------------------------------

    /// A coherent beam between two rays, drawn up to (not including) leg `last` (-1 = all).
    void RenderStrip(PathRec ra, PathRec rb, double watts, int bin, int last = -1)
    {
        if (ra.Invalid || rb.Invalid)
            return;
        int end = last < 0 ? ra.Pts.Count - 1 : last;
        int first = Math.Max(1, Math.Max(ra.Start, rb.Start));   // A variant draws from its own fork on
        if (end - first + 1 < 2)
            return;
        _render.Add(0);   // BeamGeometry.STRIP
        _render.Add(bin);
        _render.Add((float)watts);
        _render.Add(end - first + 1);   // points first..end
        for (int k = first; k <= end; k++)
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
        if (ra.Invalid || rb.Invalid)
        {
            if (!ra.Invalid)
                RenderRay(ra, watts, width, bin, 1);
            if (!rb.Invalid)
                RenderRay(rb, watts, width, bin, 1);
            return;
        }
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

        int from = Math.Max(1, Math.Max(ra.Start, rb.Start));
        if (shared < from)
        {
            RenderRay(ra, watts, width, bin, Math.Max(shared, 1));
            RenderRay(rb, watts, width, bin, Math.Max(shared, 1));
            return;
        }
        _render.Add(0);   // BeamGeometry.STRIP
        _render.Add(bin);
        _render.Add((float)(watts * 2.0));
        _render.Add(shared - from + 2);   // points from..shared, then the cut
        for (int k = from; k <= shared; k++)
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
        first = Math.Max(first, r.Start);
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
}

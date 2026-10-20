using System;
using Godot;

namespace SolarSim;

/// <summary>The source whose light a pass traces: where its rays start and what they carry.</summary>
public partial class LightEngine
{
    /// A family of rays parameterized by u, with the power each interval of u carries (design
    /// §6.11). Parallel (the sun, the moon): u is the position across the light, rays share a
    /// direction. Point (a lamp): u is the angle, rays share an origin. The beam stage only asks
    /// for a ray at u and the power of an interval, so it doesn't care what u is. The lanes of the
    /// direct stage are cells of u, LaneW wide from U0.
    sealed class Source
    {
        public bool Point;
        public readonly double[] PerU = new double[Bins];    // W per unit of u across the slice, per bin
        public readonly double[] LaneWatts = new double[Bins];   // W each lane carries, per bin
        public double U0, LaneW;
        public D2 Perp, Dir, Pos;

        /// Whether the rays of two parameters are the same ray shifted along u (the object cache
        /// needs that: identical objects then see identical rays).
        public bool Parallel => !Point;

        public D2 Direction(double u) => Point ? new D2(Math.Cos(u), Math.Sin(u)) : Dir;

        /// Start of the ray at u; `s` is how far along the light a parallel ray starts.
        public D2 Origin(double u, double s) => Point ? Pos : Perp * u + Dir * s;

        /// The point `s` along the ray at u (from its line's start for parallel light).
        public D2 At(double u, double s) => Point ? Pos + Direction(u) * s : Perp * u + Dir * s;

        /// Across the ray at u.
        public D2 LanePerp(double u)
        {
            if (!Point)
                return Perp;
            D2 d = Direction(u);
            return new D2(-d.Y, d.X);
        }

        /// Width of a lane at distance `s` along its ray, m.
        public double LaneWidthAt(double s) => Point ? LaneW * s : LaneW;

        /// Metres of wavefront per unit of u at distance r (1 for parallel light).
        public double Metres(double r) => Point ? Math.Max(r, MinRange) : 1.0;

        /// u of a point (where an object's samples are anchored).
        public double Coordinate(D2 p) => Point ? Math.Atan2(p.Y - Pos.Y, p.X - Pos.X) : p.Dot(Perp);

        /// u of lane k's left edge.
        public double Edge(int k) => U0 + k * LaneW;

        /// Power of bin b carried between u0 and u1, W.
        public double Watts(int b, double u0, double u1) => PerU[b] * (u1 - u0);

        public void SetLanes(double u0, double laneW)
        {
            U0 = u0;
            LaneW = laneW;
            for (int b = 0; b < Bins; b++)
                LaneWatts[b] = PerU[b] * laneW;
        }
    }

    /// <summary>W each lane of the direct stage carries in bin b (after a SetSource).</summary>
    public double LaneWatts(int b) => _src.LaneWatts[b];

    const double MinRange = 0.25;   // Closest distance a point source's spacing is scaled for, m

    Source _src = new();

    /// <summary>
    /// Parallel light (sun, moon): `irradiance` W/m² per bin across the light; lane k spans u =
    /// u0 + k laneW .. across `perp`, rays travel along `dir`.
    /// </summary>
    public void SetParallelSource(float[] irradiance, double u0, double laneW, Vector2 perp, Vector2 dir)
    {
        _src = new Source { Perp = D2.From(perp), Dir = D2.From(dir) };
        for (int b = 0; b < Bins; b++)
            _src.PerU[b] = irradiance[b] * _depth;
        _src.SetLanes(u0, laneW);
    }

    /// <summary>
    /// A lamp at `pos`: `intensity` W per radian per bin in the slice; lane k spans the angles
    /// angle0 + k laneRad ..
    /// </summary>
    public void SetPointSource(float[] intensity, double angle0, double laneRad, Vector2 pos)
    {
        _src = new Source { Point = true, Pos = D2.From(pos) };
        for (int b = 0; b < Bins; b++)
            _src.PerU[b] = intensity[b];
        _src.SetLanes(angle0, laneRad);
    }
}

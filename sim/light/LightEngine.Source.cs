using System;
using Godot;

namespace SolarSim;

/// <summary>The source whose light the beam stage traces: where its rays start and what they carry.</summary>
public partial class LightEngine
{
    /// A family of rays parameterized by u, with the power each interval of u carries (design
    /// §6.11). Parallel: u is the position across the light (the sun, the moon). The beam stage
    /// only asks for a ray at u and the power of an interval, so it doesn't care what u is.
    sealed class Source
    {
        public readonly double[] Irradiance = new double[Bins];   // W/m² per bin, across the light
        public double U0, LaneW;
        public D2 Perp, Dir;

        /// Whether the rays of two parameters are the same ray shifted along u (the object cache
        /// needs that: identical objects then see identical rays).
        public bool Parallel => true;

        /// Start of the ray at u, `s` along the light.
        public D2 Origin(double u, double s) => Perp * u + Dir * s;

        public D2 Direction(double u) => Dir;

        /// u of lane k's left edge.
        public double Edge(int k) => U0 + k * LaneW;

        /// u of a point (where an object's samples are anchored).
        public double Coordinate(D2 p) => p.Dot(Perp);

        /// Power of bin b carried between u0 and u1 across the slice depth, W.
        public double Watts(int b, double u0, double u1, double depth) => Irradiance[b] * (u1 - u0) * depth;
    }

    Source _src = new();
}

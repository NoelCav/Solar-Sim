using Godot;

namespace SolarSim;

/// <summary>
/// Compiled steady-state solve of the surface skin (D18, SurfaceSkin): per run of faces, the
/// strips' temperatures balance the light they absorb against conduction into their tile,
/// exchange with the tile across the face, lateral conduction along the surface and
/// radiation. A tridiagonal system per run (Thomas algorithm), radiation linearized around
/// the last temperatures. The heat that leaves each strip is added to the tiles' energy_in, so
/// light in = heat out exactly (sky radiation leaves the world).
/// </summary>
[GlobalClass]
public partial class SkinKernel : RefCounted
{
    const double Sigma = 5.670374419e-8;

    int _strips;
    int[] _faceTile = System.Array.Empty<int>(), _faceNext = System.Array.Empty<int>();
    int[] _runStart = System.Array.Empty<int>();
    byte[] _faceSky = System.Array.Empty<byte>();
    float[] _gBody = System.Array.Empty<float>(), _gNext = System.Array.Empty<float>();
    float[] _gLat = System.Array.Empty<float>(), _emissivity = System.Array.Empty<float>();
    double _area;
    double[] _a = System.Array.Empty<double>(), _b = System.Array.Empty<double>();
    double[] _c = System.Array.Empty<double>(), _d = System.Array.Empty<double>();
    double[] _gRad = System.Array.Empty<double>(), _tEnv = System.Array.Empty<double>();

    /// <summary>
    /// Per face: tile, tile across, sky-facing; per strip: conductance to its tile, to the tile
    /// across, to the next strip in its run (0 at run ends), emissivity. `stripArea` in m².
    /// </summary>
    public void Build(int strips, int[] faceTile, int[] faceNext, byte[] faceSky, int[] runStart, float[] gBody,
        float[] gNext, float[] gLat, float[] emissivity, double stripArea)
    {
        _strips = strips;
        _faceTile = faceTile;
        _faceNext = faceNext;
        _faceSky = faceSky;
        _runStart = runStart;
        _gBody = gBody;
        _gNext = gNext;
        _gLat = gLat;
        _emissivity = emissivity;
        _area = stripArea;
        int n = gBody.Length;
        _a = new double[n];
        _b = new double[n];
        _c = new double[n];
        _d = new double[n];
        _gRad = new double[n];
        _tEnv = new double[n];
    }

    /// <summary>
    /// Solves the skin for a step of dt seconds: absorbed light lightW × lightScale (W) per strip,
    /// plus energy (J) in faceEnergy per face (spread evenly over its strips); tile temperatures
    /// fixed. Returns [skin temperature, tile energy_in, face energy (cleared)].
    /// </summary>
    public Godot.Collections.Array Solve(float[] tileTemp, float[] tileEnergy, float[] lightW, double lightScale,
        float[] faceEnergy, float[] skinTemp, double dt, double skyK, bool radiation)
    {
        int s = _strips;
        double inv = dt > 0 ? 1.0 / dt : 0.0;
        for (int r = 0; r + 1 < _runStart.Length; r++)
        {
            int i0 = _runStart[r] * s, i1 = _runStart[r + 1] * s;
            for (int i = i0; i < i1; i++)
            {
                int f = i / s;
                double tTile = tileTemp[_faceTile[f]], tNext = tileTemp[_faceNext[f]];
                double tEnv = _faceSky[f] == 1 ? skyK : tNext;
                double ts = skinTemp[i];
                double gr = radiation ? _emissivity[i] * Sigma * _area * (ts * ts + tEnv * tEnv) * (ts + tEnv) : 0.0;
                double left = i > i0 ? _gLat[i - 1] : 0.0;
                double right = i + 1 < i1 ? _gLat[i] : 0.0;
                _a[i] = -left;
                _c[i] = -right;
                _b[i] = _gBody[i] + _gNext[i] + gr + left + right;
                double light = lightW[i] * lightScale + faceEnergy[f] / s * inv;
                _d[i] = light + _gBody[i] * tTile + _gNext[i] * tNext + gr * tEnv;
                _gRad[i] = gr;
                _tEnv[i] = tEnv;
            }
            // Thomas algorithm: forward sweep, back substitution.
            for (int i = i0 + 1; i < i1; i++)
            {
                double m = _a[i] / _b[i - 1];
                _b[i] -= m * _c[i - 1];
                _d[i] -= m * _d[i - 1];
            }
            skinTemp[i1 - 1] = (float)(_d[i1 - 1] / _b[i1 - 1]);
            for (int i = i1 - 2; i >= i0; i--)
                skinTemp[i] = (float)((_d[i] - _c[i] * skinTemp[i + 1]) / _b[i]);
            // Heat out of each strip, into the tiles (sky radiation leaves the world).
            for (int i = i0; i < i1; i++)
            {
                int f = i / s;
                int tile = _faceTile[f], next = _faceNext[f];
                double ts = skinTemp[i];
                tileEnergy[tile] += (float)(_gBody[i] * (ts - tileTemp[tile]) * dt);
                double toNext = _gNext[i] * (ts - tileTemp[next]);
                if (_faceSky[f] == 0)
                    toNext += _gRad[i] * (ts - _tEnv[i]);
                tileEnergy[next] += (float)(toNext * dt);
            }
            for (int f = _runStart[r]; f < _runStart[r + 1]; f++)
                faceEnergy[f] = 0f;
        }
        return new Godot.Collections.Array { skinTemp, tileEnergy, faceEnergy };
    }
}

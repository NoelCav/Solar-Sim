using Godot;

namespace SolarSim;

/// <summary>
/// Compiled inner loops of ThermalSystem (design doc §7): folding energy_in, conduction with
/// quiet-row skipping, sky radiation and ambient relaxation for one band of rows.
/// ThermalSystem (GDScript) owns the model and builds the per-tile tables; this class only
/// runs the arithmetic. Results match the GDScript implementation it replaced.
/// </summary>
[GlobalClass]
public partial class HeatKernel : RefCounted
{
    /// <summary>Stefan–Boltzmann constant, W/(m²·K⁴): the C# home of SimConst.STEFAN_BOLTZMANN.</summary>
    public const double StefanBoltzmann = 5.670374419e-8;

    const float FlatEpsK = 1e-4f;   // Temperature differences below this count as none

    int _w, _h;
    float[] _invC = System.Array.Empty<float>();
    float[] _gRight = System.Array.Empty<float>();
    float[] _gDown = System.Array.Empty<float>();
    byte[] _vertGas = System.Array.Empty<byte>();
    byte[] _isGas = System.Array.Empty<byte>();
    byte[] _rowFlat = System.Array.Empty<byte>();
    int[] _sky = System.Array.Empty<int>();
    float[] _skyEmissivity = System.Array.Empty<float>();
    double _skyArea;
    float[] _dq = System.Array.Empty<float>();
    int[] _touched = System.Array.Empty<int>();

    /// <summary>Per-tile tables, rebuilt when the grid's structure changes.</summary>
    public void Build(int width, int height, float[] invC, float[] gRight, float[] gDown, byte[] vertGas,
        byte[] isGas, int[] skyTiles, float[] skyEmissivity, double skyArea)
    {
        _w = width;
        _h = height;
        _invC = invC;
        _gRight = gRight;
        _gDown = gDown;
        _vertGas = vertGas;
        _isGas = isGas;
        _sky = skyTiles;
        _skyEmissivity = skyEmissivity;
        _skyArea = skyArea;
        _dq = new float[width * height];
        _rowFlat = new byte[height];
        _touched = new int[height + 1];
    }

    /// <summary>
    /// One heat step of h seconds for the pairs owned by rows [row0, row1). Updates
    /// temperature and clears energy_in for the band; returns [temperature, energy_in].
    /// </summary>
    public Godot.Collections.Array StepRows(float[] temp, float[] energy, double h, int row0, int row1,
        int subcycles, bool conduction, bool radiation, bool ambient, bool quietRows,
        double ambientK, double skyK, double buoyancyBoost, double relaxPerS)
    {
        int w = _w;
        int i0 = row0 * w;
        int i1 = row1 * w;
        for (int i = i0; i < i1; i++)
        {
            if (energy[i] != 0f)
            {
                temp[i] = (float)(temp[i] + (double)energy[i] * _invC[i]);
                energy[i] = 0f;
                _rowFlat[i / w] = 0;
            }
        }
        if (conduction)
        {
            double hs = h / subcycles;
            for (int k = 0; k < subcycles; k++)
                Conduct(temp, hs, row0, row1, k == 0 && quietRows, buoyancyBoost);
        }
        if (radiation)
            Radiate(temp, h, i0, i1, ambientK, skyK);
        if (ambient)
        {
            double keep = System.Math.Exp(-relaxPerS * h);
            for (int i = i0; i < i1; i++)
                if (_isGas[i] == 1)
                    temp[i] = (float)(ambientK + (temp[i] - ambientK) * keep);
        }
        RefreshFlat(temp, row0, System.Math.Min(row1 + 1, _h));
        return new Godot.Collections.Array { temp, energy };
    }

    void Conduct(float[] temp, double hs, int row0, int row1, bool skipQuiet, double boost)
    {
        int w = _w, h = _h;
        float[] dq = _dq, gr = _gRight, gd = _gDown;
        int touchedCount = 0;
        for (int y = row0; y < row1; y++)
        {
            if (skipQuiet && _rowFlat[y] == 1 && (y == h - 1
                    || (_rowFlat[y + 1] == 1 && System.Math.Abs(temp[y * w] - temp[(y + 1) * w]) <= FlatEpsK)))
                continue;
            if (touchedCount == 0 || _touched[touchedCount - 1] != y)
                _touched[touchedCount++] = y;
            if (y + 1 < h)
                _touched[touchedCount++] = y + 1;
            int end = y * w + w;
            for (int i = y * w; i < end; i++)
            {
                double ti = temp[i];
                double c = gr[i];
                if (c > 0.0)
                {
                    double q = c * (ti - temp[i + 1]);
                    dq[i] = (float)(dq[i] - q);
                    dq[i + 1] = (float)(dq[i + 1] + q);
                }
                c = gd[i];
                if (c > 0.0)
                {
                    double tj = temp[i + w];
                    if (_vertGas[i] == 1 && tj > ti)
                        c *= boost;
                    double q = c * (ti - tj);
                    dq[i] = (float)(dq[i] - q);
                    dq[i + w] = (float)(dq[i + w] + q);
                }
            }
        }
        for (int t = 0; t < touchedCount; t++)
        {
            int y = _touched[t];
            int end = y * w + w;
            for (int i = y * w; i < end; i++)
            {
                temp[i] = (float)(temp[i] + (double)dq[i] * hs * _invC[i]);
                dq[i] = 0f;
            }
        }
    }

    void Radiate(float[] temp, double h, int i0, int i1, double ambientK, double skyK)
    {
        double sky4 = skyK * skyK * skyK * skyK;
        double area = _skyArea;
        for (int k = 0; k < _sky.Length; k++)
        {
            int i = _sky[k];
            if (i < i0 || i >= i1)
                continue;
            double t = temp[i];
            double p = _skyEmissivity[k] * StefanBoltzmann * (t * t * t * t - sky4) * area;
            double dt = p * h * _invC[i];
            temp[i] = (float)(System.Math.Abs(dt) < System.Math.Abs(t - skyK) ? t - dt : skyK);
        }
    }

    void RefreshFlat(float[] temp, int row0, int row1)
    {
        int w = _w;
        for (int y = row0; y < row1; y++)
        {
            int b = y * w;
            float t0 = temp[b];
            byte f = 1;
            for (int i = b + 1; i < b + w; i++)
            {
                if (System.Math.Abs(temp[i] - t0) > FlatEpsK)
                {
                    f = 0;
                    break;
                }
            }
            _rowFlat[y] = f;
        }
    }
}

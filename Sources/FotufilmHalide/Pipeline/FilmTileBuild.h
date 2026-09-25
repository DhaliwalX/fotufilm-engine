#ifndef FOTUFILM_FILM_TILE_BUILD_PIPELINE_H
#define FOTUFILM_FILM_TILE_BUILD_PIPELINE_H

#include "../Stages/Random.h"

#include <Halide.h>
#include <cmath>
#include <string>
#include <vector>

namespace fotufilm::pipelines {

/// Sublayers one build lays: `CrystalGrainModel.binCount`.
constexpr int kFilmBuildSublayers = 4;
/// Crystals a film cell holds at most: `FilmRandom.maxCount`.
constexpr int kFilmBuildMaxCount = 48;
/// Film cells a sample's footprint can meet along one axis: a cell is at least three quarters of
/// a sample, and the footprint two samples wide.
constexpr int kFilmBuildCellWindow = 4;
/// Most film cells along a tile side.
constexpr int kFilmBuildMaxCells = 1024;
/// Per sublayer: cells per tile side, peak demand over capacity, capacity, then the count
/// thresholds `FilmRandom.countThresholds` gives.
constexpr int kFilmBuildFields = 3 + kFilmBuildMaxCount;

/// One Gaussian term of the dye cloud, in samples.
struct FilmCloudTerm {
    float sigma;
    float weight;
};

/// A normalised Gaussian of `sigma` samples, 3.5 sigma either side: `FilmGrain.gaussianKernel`.
inline std::vector<float> film_gaussian_kernel(float sigma) {
    int radius = std::max(int(std::ceil(3.5f * sigma)), 1);
    std::vector<float> kernel;
    float total = 0;
    for (int t = -radius; t <= radius; ++t) {
        float v = std::exp(-float(t * t) / (2 * sigma * sigma));
        kernel.push_back(v);
        total += v;
    }
    for (float &v : kernel) v /= total;
    return kernel;
}

/// Grid factor a term is blurred at: `FilmGrain.layCloudTerm`'s rule, held to a divisor of the
/// periodic tile so the coarse grid is periodic too.
inline int film_term_factor(float sigma, int samples) {
    int factor = std::max(int(sigma / 1.6f), 1);
    while (factor > 1 && samples % factor != 0) --factor;
    return factor;
}

/// One dye-cloud record's periodic tile, crystal by crystal, at every requested developed
/// density at once: the arithmetic of `FilmGrain.renderTile` on a tile that wraps.
///
/// Each sample gathers the crystals of the film cells its bilinear footprint meets, hashed as
/// `FilmRandom` hashes them, so the tile is the same film the Swift reference lays. A crystal
/// develops at a level where its draw falls under the level's developed fraction; the level is
/// the innermost loop, so a crystal's draws are made once for every level. The cloud's terms blur
/// the deposits — the narrow ones directly, the wide ones on a coarser periodic grid — each
/// sublayer's demand saturates against its capacity, and a texel's light is the mean of its
/// samples' transmittance.
///
/// `sublayers(field, b)` holds `kFilmBuildFields` per sublayer; `fractions(level, b)` each
/// sublayer's developed fraction at the output's levels. The output is `light(X, Y, level)`.
struct FilmTileBuildPipeline {
    Halide::ImageParam sublayers{Halide::Float(32), 2, "film_build_sublayers"};
    Halide::ImageParam fractions{Halide::Float(32), 2, "film_build_fractions"};
    Halide::Param<uint32_t> seed{"film_build_seed"};
    Halide::Param<int32_t> record{"film_build_record"};
    /// Per sublayer, the film cells along a tile side (field 0 of `sublayers`) and the most
    /// crystals a cell can hold: the count thresholds a uniform draw can pass.
    Halide::Param<int32_t> cellCounts[kFilmBuildSublayers] = {
        Halide::Param<int32_t>{"film_build_cells0"}, Halide::Param<int32_t>{"film_build_cells1"},
        Halide::Param<int32_t>{"film_build_cells2"}, Halide::Param<int32_t>{"film_build_cells3"}};
    Halide::Param<int32_t> limits[kFilmBuildSublayers] = {
        Halide::Param<int32_t>{"film_build_limit0"}, Halide::Param<int32_t>{"film_build_limit1"},
        Halide::Param<int32_t>{"film_build_limit2"}, Halide::Param<int32_t>{"film_build_limit3"}};
    Halide::Func output{"film_build_light"};

    FilmTileBuildPipeline(int texels, int supersample, int markShape,
                          const std::vector<FilmCloudTerm> &terms) {
        using namespace Halide;
        const int n = texels * supersample;
        const uint32_t golden = 0x9E3779B9u;
        Var x("x"), y("y"), l("l"), cx("cx"), cy("cy");

        auto wrap = [](Expr v, int period) { return v % period; };
        auto uniform = [](Expr hash) {
            return (cast<float>(hash >> 8) + 0.5f) * (1.0f / 16777216.0f);
        };
        auto key = [&](Expr base, Expr hx, Expr hy) {
            return pcg(cast<uint32_t>(hx) ^ pcg(cast<uint32_t>(hy) ^ pcg(base)));
        };
        auto draw = [&](Expr k, Expr index) {
            return pcg(k ^ (cast<uint32_t>(index) * Expr(golden)));
        };
        auto schedule2 = [&](Func f, Var a, Var b) { f.compute_root().reorder(l, a, b).parallel(b); };

        Func dye("film_build_dye");
        Expr dyeTotal = 0.0f;
        for (int b = 0; b < kFilmBuildSublayers; ++b) {
            std::string tag = "film_build_" + std::to_string(b);
            Expr cells = cellCounts[b];
            Expr edge = sublayers(1, b), capacity = sublayers(2, b);
            Expr cellSize = float(n) / cast<float>(cells);
            Expr stream = cast<uint32_t>(record * 8 + b * 2);
            Expr crystalBase = seed ^ (stream * Expr(golden));
            Expr countBase = seed ^ ((stream + 1) * Expr(golden));

            // Crystals per cell: the cell's count draw against the Poisson thresholds.
            Func count(tag + "_count");
            RDom k(0, kFilmBuildMaxCount, tag + "_thresholds");
            Expr u = uniform(draw(key(countBase, cx, cy), 0));
            count(cx, cy) = sum(select(sublayers(3 + k, b) < u, 1, 0), tag + "_count_sum");
            count.bound(cx, 0, cells).bound(cy, 0, cells);
            count.compute_root().parallel(cy);

            // Every crystal of every cell, drawn once: its place in the cell, the draw it
            // develops at, and its peak demand over capacity.
            Var c("c");
            Func crystal(tag + "_crystal");
            {
                Expr hash = key(crystalBase, cx, cy);
                Expr first = c * (3 + markShape);
                Expr mark = 0.0f;
                for (int i = 0; i < markShape; ++i) {
                    mark = mark - log(max(uniform(draw(hash, first + 3 + i)), 1.0e-7f));
                }
                crystal(c, cx, cy) = Tuple(
                    uniform(draw(hash, first)),
                    uniform(draw(hash, first + 1)),
                    uniform(draw(hash, first + 2)),
                    edge * (mark / float(markShape)));
            }
            crystal.bound(c, 0, limits[b]).bound(cx, 0, cells).bound(cy, 0, cells);
            crystal.compute_root().reorder(c, cx, cy).parallel(cy);

            // Each sample's share of the peak demand of every crystal whose bilinear footprint
            // covers it, per level.
            Func deposit(tag + "_deposit");
            deposit(x, y, l) = 0.0f;
            Expr sx = cast<float>(x) + 0.5f, sy = cast<float>(y) + 0.5f;
            Expr cx0 = cast<int>(floor((sx - 1.0f) / cellSize));
            Expr cy0 = cast<int>(floor((sy - 1.0f) / cellSize));
            Expr cx1 = cast<int>(floor((sx + 1.0f) / cellSize));
            Expr cy1 = cast<int>(floor((sy + 1.0f) / cellSize));
            RDom r(0, kFilmBuildCellWindow, 0, kFilmBuildCellWindow, 0, limits[b], tag + "_crystals");
            Expr ux = cx0 + r.x, uy = cy0 + r.y;
            Expr hx = clamp(ux % cells, 0, cells - 1);
            Expr hy = clamp(uy % cells, 0, cells - 1);
            r.where(r.x <= cx1 - cx0 && r.y <= cy1 - cy0 && r.z < count(hx, hy));
            Expr px = (cast<float>(ux) + crystal(r.z, hx, hy)[0]) * cellSize;
            Expr py = (cast<float>(uy) + crystal(r.z, hx, hy)[1]) * cellSize;
            Expr share = max(0.0f, 1.0f - abs(px - sx)) * max(0.0f, 1.0f - abs(py - sy));
            deposit(x, y, l) += select(crystal(r.z, hx, hy)[2] < fractions(l, b),
                                       share * crystal(r.z, hx, hy)[3], 0.0f);
            deposit.compute_root().reorder(l, x, y).parallel(y);
            deposit.update(0).reorder(l, r.z, r.x, r.y, x, y).parallel(y);

            // The demand: every term of the cloud, times its weight · 2π σ².
            Expr demand = 0.0f;
            for (size_t i = 0; i < terms.size(); ++i) {
                const float sigma = terms[i].sigma;
                const float scale = terms[i].weight * 2 * float(M_PI) * sigma * sigma;
                const int factor = film_term_factor(sigma, n);
                std::string name = tag + "_term" + std::to_string(i);
                if (factor == 1) {
                    std::vector<float> kernel = film_gaussian_kernel(sigma);
                    int radius = int(kernel.size()) / 2;
                    Func across(name + "_across");
                    Expr sum = 0.0f;
                    for (int t = 0; t < int(kernel.size()); ++t) {
                        sum += kernel[t] * deposit(wrap(x + t - radius + n, n), y, l);
                    }
                    across(x, y, l) = sum;
                    schedule2(across, x, y);
                    Expr down = 0.0f;
                    for (int t = 0; t < int(kernel.size()); ++t) {
                        down += kernel[t] * across(x, wrap(y + t - radius + n, n), l);
                    }
                    demand += scale * down;
                    continue;
                }
                // Deposits shared linearly into cells `factor` samples a side, blurred there by
                // what is left of the term after the two tents, and read back linearly.
                const int m = n / factor;
                const float f = float(factor);
                std::vector<float> tent;
                for (int t = 0; t < 3 * factor; ++t) {
                    tent.push_back(std::max(0.0f, 1.0f - std::fabs((t + 0.5f) / f - 1.5f)));
                }
                Var i0("i0"), j0("j0");
                Func rows(name + "_rows"), cellsum(name + "_cells");
                Expr rowSum = 0.0f;
                for (int t = 0; t < int(tent.size()); ++t) {
                    if (tent[t] > 0) rowSum += tent[t] * deposit(wrap(factor * i0 - factor + t + n, n), y, l);
                }
                rows(i0, y, l) = rowSum;
                schedule2(rows, i0, y);
                Expr cellSum = 0.0f;
                for (int t = 0; t < int(tent.size()); ++t) {
                    if (tent[t] > 0) cellSum += tent[t] * rows(i0, wrap(factor * j0 - factor + t + n, n), l);
                }
                cellsum(i0, j0, l) = cellSum;
                schedule2(cellsum, i0, j0);
                std::vector<float> kernel =
                    film_gaussian_kernel(std::sqrt(sigma * sigma - f * f / 3) / f);
                int radius = int(kernel.size()) / 2;
                Func across(name + "_across"), blurred(name + "_blurred");
                Expr sum = 0.0f;
                for (int t = 0; t < int(kernel.size()); ++t) {
                    sum += kernel[t] * cellsum(wrap(i0 + t - radius + m, m), j0, l);
                }
                across(i0, j0, l) = sum;
                schedule2(across, i0, j0);
                Expr down = 0.0f;
                for (int t = 0; t < int(kernel.size()); ++t) {
                    down += kernel[t] * across(i0, wrap(j0 + t - radius + m, m), l);
                }
                blurred(i0, j0, l) = down;
                schedule2(blurred, i0, j0);
                Expr uf = (cast<float>(x) + 0.5f) / f - 0.5f;
                Expr vf = (cast<float>(y) + 0.5f) / f - 0.5f;
                Expr iu = cast<int>(floor(uf)), iv = cast<int>(floor(vf));
                Expr au = uf - cast<float>(iu), av = vf - cast<float>(iv);
                Expr a0 = wrap(iu + m, m), a1 = wrap(iu + 1 + m, m);
                Expr b0 = wrap(iv + m, m), b1 = wrap(iv + 1 + m, m);
                Expr read = (blurred(a0, b0, l) * (1.0f - au) + blurred(a1, b0, l) * au) * (1.0f - av)
                    + (blurred(a0, b1, l) * (1.0f - au) + blurred(a1, b1, l) * au) * av;
                demand += (scale / (f * f)) * read;
            }
            dyeTotal += capacity * (1.0f - exp(-demand));
        }
        dye(x, y, l) = dyeTotal;

        // A texel passes the mean of its samples' transmittance.
        Var X("X"), Y("Y");
        Expr light = 0.0f;
        for (int j = 0; j < supersample; ++j) {
            for (int i = 0; i < supersample; ++i) {
                light += exp(-2.302585093f * dye(supersample * X + i, supersample * Y + j, l));
            }
        }
        output(X, Y, l) = light / float(supersample * supersample);
        output.bound(X, 0, texels).bound(Y, 0, texels);
        sublayers.dim(0).set_bounds(0, kFilmBuildFields).dim(1).set_bounds(0, kFilmBuildSublayers);
        fractions.dim(1).set_bounds(0, kFilmBuildSublayers);
        output.reorder(l, X, Y).parallel(Y);
    }
};

}  // namespace fotufilm::pipelines

#endif

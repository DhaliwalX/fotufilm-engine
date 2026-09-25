#pragma once
#include "fixture.h"
#include "FotufilmAotVariants.h"
#include <string>

inline int case_mask(const std::string &name, int stock) {
    struct Stage { const char *name; int bits; };
    const Stage stages[] = {
        {"stage-mtf", FOTUFILM_FRAME_MTF},
        {"stage-luma", FOTUFILM_FRAME_MTF | FOTUFILM_FRAME_MTF_LUMA},
        {"stage-halation", FOTUFILM_FRAME_HALATION},
        {"stage-couplers", FOTUFILM_FRAME_COUPLERS | FOTUFILM_FRAME_COUPLER_DIFFUSION},
        {"stage-adjacency", FOTUFILM_FRAME_ADJACENCY},
        {"stage-grain", FOTUFILM_FRAME_GRAIN},
        {"stage-mottle", FOTUFILM_FRAME_GRAIN | FOTUFILM_FRAME_GRAIN_MOTTLE},
        {"stage-print-mtf", FOTUFILM_FRAME_PRINT_MTF},
        {"stage-diffusion", FOTUFILM_FRAME_DIFFUSION},
        {"stage-flare", FOTUFILM_FRAME_FLARE},
        {"stage-donor", FOTUFILM_FRAME_DONOR_LAYER},
    };
    for (auto stage : stages) if (name == stage.name)
        return (stock & (FOTUFILM_FRAME_MONOCHROME | FOTUFILM_FRAME_REVERSAL)) | stage.bits;
    if(name=="plain") return FOTUFILM_FRAME_NO_FILM;
    if(name=="print") return FOTUFILM_FRAME_DENSITY_IN | FOTUFILM_FRAME_PRINT_MTF;
    if(name=="pointwise") return stock & ~FOTUFILM_AOT_FULL_STAGES;
    if(name=="all" || name=="annular") return stock | FOTUFILM_AOT_FULL_STAGES
        | (name=="annular" ? FOTUFILM_FRAME_HALATION_ANNULAR : 0);
    if(name=="stock" || name=="viewport") return stock;
    throw std::runtime_error("Unknown test case");
}

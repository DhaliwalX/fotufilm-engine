#include <stdint.h>
#include <emscripten/emscripten.h>
#include "parity_math.h"
extern "C" EMSCRIPTEN_KEEPALIVE int run_math(float *input,float *output,int count) {
    if (!input || !output || count <= 0) return -1;
    halide_dimension_t in_dims[]={{0,count,1,0},{0,3,count,0}};
    halide_dimension_t out_dims[]={{0,count,1,0},{0,14,count,0}};
    halide_buffer_t in={}, out={};
    in.host=(uint8_t*)input; in.dim=in_dims; in.dimensions=2;
    out.host=(uint8_t*)output; out.dim=out_dims; out.dimensions=2;
    in.type=out.type=halide_type_t(halide_type_float,32);
    in.flags=halide_buffer_flag_host_dirty;
    int status=math_kernel(&in,&out);
    if(status==0) status=halide_copy_to_host(nullptr,&out);
    halide_device_free(nullptr,&in);halide_device_free(nullptr,&out);
    return status;
}

#include "FotufilmNegativeScan.h"
#include <vector>
#include <cstdio>
#include <cmath>
#include <limits>
int main() {
    constexpr int width = 513, height = 19, n = width * height;
    std::vector<float> scan(n*3), output(n*3);
    float p[] = {.04f,.025f,.015f,.7f,.35f,.15f,.6f,0};
    for (int c=0;c<3;++c) for (int i=0;i<n;++i)
        scan[c*n+i] = p[c] * .5f + (p[c+3] - p[c] * .5f) * float(i)/float(n-1);
    scan[0] = std::numeric_limits<float>::quiet_NaN();
    scan[n+1] = 0;
    for (int mono=0;mono<2;++mono) for (int backend=0;backend<2;++backend) {
        p[7] = float(mono);
        int status = fotufilm_negative_scan(scan.data(), output.data(), width, height, p, backend);
        if (status) { std::fprintf(stderr,"negative backend %d: %d\n",backend,status); return 1; }
        float low=1, high=0;
        for (float v : output) {
            if (!std::isfinite(v) || v < 0 || v > 1) return 2;
            low=std::fmin(low,v);high=std::fmax(high,v);
        }
        if (high-low < .5f) return 3;
        for (int c=0;c<3;++c) if (output[c*n] != 0 || output[c*n+1] != 0) return 4;
        if (std::fwrite(output.data(),sizeof(float),output.size(),stdout)!=output.size()) return 5;
    }
}

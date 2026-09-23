#include "quality.h"
#include <array>
#include <cassert>

int main() {
    Quality q;
    assert(!q.accepts(0)); // An unexecuted display comparison is not a pass.
    std::array<uint8_t, 1000> reference{}, actual{};
    actual[0] = 1;
    q.rgba8_maximum=q.display_error<uint8_t>(reference.data(),actual.data(),1000,true);
    assert(q.accepts(0.0001f));
    assert(!q.accepts(0.000101f));
    q.rmse=0.0000101;
    assert(!q.accepts(0));
    q.rmse=0;
    ++q.rgba8_changed;
    assert(!q.accepts(0));
    --q.rgba8_changed;
    q.rgba8_maximum=2;
    assert(!q.accepts(0));
    q.rgba8_maximum=1;
    uint16_t a=255,b=256;
    q.rgba16_maximum=q.display_error<uint16_t>(&a,&b,sizeof(a),false);
    assert(q.rgba16_maximum==1); // Two changed bytes, but only one code value.
    assert(q.accepts(0));
    q.rgba16_maximum=5;
    assert(!q.accepts(0));
}

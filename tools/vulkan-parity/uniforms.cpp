#include "HalideBuffer.h"
#include "uniforms.h"
#include <cstdio>
#include <cstdlib>
int main() {
    setenv("HL_VK_ALLOC_CONFIG","0:1:0:0:256",0);
    Halide::Runtime::Buffer<uint32_t> input(65),output(65);
    for(int x=0;x<65;++x)input(x)=uint32_t(x)*17;
    input.set_host_dirty();int failures=0;
    for(bool add : {false,true})for(bool invert : {false,true}) {
        int status=uniforms(input,add,invert,123,output);
        if(!status)status=output.copy_to_host();
        size_t different=0;
        if(!status)for(int x=0;x<65;++x) {
            uint32_t expected=add?input(x)+123:input(x)-123;
            if(invert)expected=~expected;
            different+=output(x)!=expected;
        }
        printf("{\"add\":%s,\"invert\":%s,\"status\":%d,\"values_different\":%zu}\n",
               add?"true":"false",invert?"true":"false",status,different);
        failures+=status!=0||different!=0;
    }
    return failures?1:0;
}

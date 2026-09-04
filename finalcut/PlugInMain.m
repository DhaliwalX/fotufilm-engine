// The extension's entry point.
//
// PlugInKit launches this executable; `FxPrincipal` — which the FxPlug framework supplies — stands
// up the XPC service and hands the host our effect class, named in Info.plist. Nothing of ours runs
// before it. This is the FxPlug 4 template's `main` verbatim, and it is the whole file for a
// reason: the entry point is the SDK's to define.

#import <FxPlug/FxPlugSDK.h>

int main(int argc, const char *argv[]) {
    [FxPrincipal startServicePrincipal];
}

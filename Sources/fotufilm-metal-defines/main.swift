@_spi(BuildTools) import FotufilmMetal

for (name, value) in HandwrittenMetalBuildConstants.compilerDefinitions().sorted(by: { $0.key < $1.key }) {
    print("-D\(name)=\(value)")
}

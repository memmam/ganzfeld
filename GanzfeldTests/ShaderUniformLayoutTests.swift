import Testing
import Metal
import simd

@testable import Ganzfeld

/// `ShaderUniforms` is copied byte-for-byte into the fragment shader's
/// constant buffer, so its layout must match `Uniforms` in Shaders.metal.
/// Metal packs `float4` at 16-byte alignment followed by four `uint`s, giving
/// a 32-byte struct — the two `pad` fields exist purely to reach it.
@Suite("Shader uniform layout")
struct ShaderUniformLayoutTests {

    @Test("the struct is 32 bytes with 16-byte alignment")
    func size() {
        #expect(MemoryLayout<ShaderUniforms>.size == 32)
        #expect(MemoryLayout<ShaderUniforms>.stride == 32)
        #expect(MemoryLayout<ShaderUniforms>.alignment == 16)
    }

    @Test("fields sit at the offsets Metal expects")
    func offsets() throws {
        #expect(try #require(MemoryLayout<ShaderUniforms>.offset(of: \.color)) == 0)
        #expect(try #require(MemoryLayout<ShaderUniforms>.offset(of: \.targetEye)) == 16)
        #expect(try #require(MemoryLayout<ShaderUniforms>.offset(of: \.viewOffset)) == 20)
        #expect(try #require(MemoryLayout<ShaderUniforms>.offset(of: \.pad0)) == 24)
        #expect(try #require(MemoryLayout<ShaderUniforms>.offset(of: \.pad1)) == 28)
    }

    @Test("padding defaults to zero so uninitialised bytes never reach the GPU")
    func paddingDefaultsToZero() {
        let uniforms = ShaderUniforms(color: SIMD4(1, 2, 3, 4), targetEye: 1)
        #expect(uniforms.viewOffset == 0)
        #expect(uniforms.pad0 == 0)
        #expect(uniforms.pad1 == 0)
    }

    @Test("the bytes handed to setFragmentBytes carry the colour first")
    func byteLayout() {
        var uniforms = ShaderUniforms(color: SIMD4(0.25, 0.5, 0.75, 1), targetEye: 2, viewOffset: 1)
        let bytes = withUnsafeBytes(of: &uniforms) { Array($0) }
        #expect(bytes.count == 32)

        let floats = bytes.withUnsafeBytes { $0.loadUnaligned(as: SIMD4<Float>.self) }
        #expect(floats == SIMD4<Float>(0.25, 0.5, 0.75, 1))

        let target = bytes[16..<20].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let offset = bytes[20..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(target == 2)
        #expect(offset == 1)
    }
}

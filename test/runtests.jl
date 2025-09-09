using StructIO
using Test
import REPL # needed for docstrings on nightly: julia#55438

# First, exercise the `@io` macro a bit, to ensure it can handle different
# kinds of type declarations
@io struct TwoUInts
    x::UInt
    y::UInt
end

abstract type AbstractType end
@io struct ConcreteType <: AbstractType
    A::UInt32
    B::UInt16
    C::UInt128
    D::UInt8
end align_packed

@io struct PackedNestedType
    A::ConcreteType
    B::ConcreteType
end align_packed

@io struct DefaultNestedType
    A::ConcreteType
    B::ConcreteType
end

@io struct PackedParametricType{T}
    x::T
    y::T
end align_packed

# Structs with gaps
@io struct RawData
    A::UInt32
    dummy_1::UInt8
    dummy_2::UInt16
    B::UInt16
    dummy_3::UInt32
    C::UInt128
    dummy_4::UInt16
    dummy_5::UInt64
    D::UInt8
    dummy_6::UInt8
end align_packed

@io struct GappedStruct
    A::UInt32
    _::3
    B::UInt16
    _::4
    C::UInt128
    _::2
    _::8
    _D::UInt8
    _::1
end align_packed


# Also test documenting a type
"""
This is a docstring
"""
@io struct ParametricType{S,T}
    A::S
    B::T
    C::T
end

@testset "unpack()" begin
    # Test native unpacking
    buf = IOBuffer()
    write(buf, UInt(1))
    write(buf, UInt(2))
    seekstart(buf)
    @test unpack(buf, TwoUInts) == TwoUInts(1,2)

    # Now, test explicitly setting the endianness
    for endian in [:LittleEndian, :BigEndian]
        buf = IOBuffer()
        write(buf, fix_endian(UInt32(1), endian))
        write(buf, fix_endian(UInt16(2), endian))
        write(buf, fix_endian(UInt128(3), endian))
        write(buf, fix_endian(UInt8(4),  endian))
        seekstart(buf)

        @test unpack(buf, ConcreteType, endian) == ConcreteType(1, 2, 3, 4)
    end

    # Test packed nested types across endianness
    for endian in [:LittleEndian, :BigEndian]
        buf = IOBuffer()
        write(buf, fix_endian(UInt32(1), endian))
        write(buf, fix_endian(UInt16(2), endian))
        write(buf, fix_endian(UInt128(3), endian))
        write(buf, fix_endian(UInt8(4), endian))
        write(buf, fix_endian(UInt32(5), endian))
        write(buf, fix_endian(UInt16(6), endian))
        write(buf, fix_endian(UInt128(7), endian))
        write(buf, fix_endian(UInt8(8), endian))
        seekstart(buf)

        x = PackedNestedType(ConcreteType(1,2,3,4), ConcreteType(5,6,7,8))
        @test unpack(buf, PackedNestedType, endian) == x
    end

    # Test mixed Packed/Default nested types across endianness
    for endian in [:BigEndian, :LittleEndian]
        # Helper function to write a value, then write zeros afterward to build
        # a stream that mocks up a `Default` packing strategy memory layout
        function write_skip(buf, x, field_idx)
            n_written = write(buf, fix_endian(x, endian))

            n_size = Int32(StructIO.fieldsize(ConcreteType, field_idx))
            write(buf, zeros(UInt8, n_size - n_written))
        end

        buf = IOBuffer()
        write_skip(buf, UInt32(1), 1)
        write_skip(buf, UInt16(2), 2)
        write_skip(buf, UInt128(3), 3)
        write_skip(buf, UInt8(4), 4)

        write_skip(buf, UInt32(5), 1)
        write_skip(buf, UInt16(6), 2)
        write_skip(buf, UInt128(7), 3)
        write_skip(buf, UInt8(8), 4)
        seekstart(buf)

        x = DefaultNestedType(ConcreteType(1,2,3,4), ConcreteType(5,6,7,8))
        @test unpack(buf, DefaultNestedType, endian) == x
    end
end

@testset "pack()" begin
    # Pack simple types
    for endian in [:BigEndian, :LittleEndian]
        buf = IOBuffer()
        pack(buf, UInt8(1), endian)
        pack(buf, Int16(2), endian)
        pack(buf, UInt32(4), endian)
        pack(buf, Int64(8), endian)
        pack(buf, UInt128(16), endian)
        @test position(buf) == 1 + 2 + 4 + 8 + 16
        seekstart(buf)
        @test unpack(buf, UInt8, endian) === UInt8(1)
        @test unpack(buf, Int16, endian) === Int16(2)
        @test unpack(buf, UInt32, endian) === UInt32(4)
        @test unpack(buf, Int64, endian) === Int64(8)
        @test unpack(buf, UInt128, endian) === UInt128(16)
    end

    # Pack a simple object
    buf = IOBuffer()
    tu = TwoUInts(2, 3)
    pack(buf, tu)

    # Test that the stream looks reasonable
    @test position(buf) == sizeof(TwoUInts)
    seekstart(buf)
    @test read(buf, UInt) == 2
    @test read(buf, UInt) == 3

    # Test that we can unpack a packed stream
    buf = IOBuffer()
    pack(buf, tu)
    seekstart(buf)
    @test unpack(buf, TwoUInts) == TwoUInts(2, 3)

    # Test packed/default nested types across endianness
    for NT in [PackedNestedType, DefaultNestedType]
        for endian in [:LittleEndian, :BigEndian]
            buf = IOBuffer()
            nt = NT(ConcreteType(1,2,3,4), ConcreteType(5,6,7,8))
            pack(buf, nt)
            seekstart(buf)
            @test unpack(buf, NT) == nt
        end
    end
end

@testset "packed_sizeof()" begin
    @test packed_sizeof(TwoUInts) == 2*sizeof(UInt)
    @test packed_sizeof(ConcreteType) == 1 + 2 + 4 + 16
    @test packed_sizeof(PackedNestedType) == 2*packed_sizeof(ConcreteType)
    @test packed_sizeof(PackedParametricType{UInt8}) == 2
    @test packed_sizeof(PackedParametricType{UInt32}) == 8
    psCT = packed_sizeof(ConcreteType)
    @test packed_sizeof(PackedParametricType{ConcreteType}) == 2*psCT
end

@testset "Documentation" begin
    @test string(@doc ParametricType) == "This is a docstring\n"
end

@testset "Struct with gaps" begin
    A,B,C,D = 1,2,3,4
    gapped_struct =  GappedStruct(A, B, C, D)
    raw_data = RawData(A, 0xBE, 0xBEEF, B, 0xDEADBEEF, C, 0xBEEF, 0xDEADBEEFDEADBEEF,
                       D, 0xBE);
    unpacked_raw_data = RawData(A, 0, 0, B, 0, C, 0, 0, D, 0);
    #
    @test all(StructIO.field_gaps(GappedStruct) .== [0, 3, 4, 10, 1])
    @test packed_sizeof(RawData) == packed_sizeof(GappedStruct)
	for endian in [:LittleEndian, :BigEndian]
        buf = IOBuffer()
        pack(buf, raw_data, endian)
        seekstart(buf)
        @test unpack(buf, GappedStruct, endian) == gapped_struct
        @test eof(buf)
        #
        buf = IOBuffer(zeros(UInt8, packed_sizeof(GappedStruct)), read=true, write=true)
        pack(buf, gapped_struct, endian)
        @test eof(buf)
        seekstart(buf)
        @test unpack(buf, GappedStruct, endian) == gapped_struct
        @test eof(buf)
        seekstart(buf)
        @test unpack(buf, RawData, endian) == unpacked_raw_data
    end
end

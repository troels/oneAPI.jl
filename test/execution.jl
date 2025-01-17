import Adapt

using StaticArrays

dummy() = return

@testset "@oneapi" begin

@test_throws UndefVarError @oneapi undefined()
@test_throws MethodError @oneapi dummy(1)


@testset "low-level interface" begin
    k = zefunction(dummy)
    k()
    k(; items=1)
end


@testset "launch configuration" begin
    @oneapi dummy()

    @oneapi items=1 dummy()
    @oneapi items=(1,1) dummy()
    @oneapi items=(1,1,1) dummy()

    @oneapi groups=1 dummy()
    @oneapi groups=(1,1) dummy()
    @oneapi groups=(1,1,1) dummy()
end


@testset "launch=false" begin
    k = @oneapi launch=false dummy()
    k()
    k(; items=1)
end


@testset "inference" begin
    foo() = @oneapi dummy()
    @inferred foo()

    # with arguments, we call kernel_convert
    kernel(a) = return
    bar(a) = @oneapi kernel(a)
    @inferred bar(oneArray([1]))
end


@testset "reflection" begin
    oneAPI.code_lowered(dummy, Tuple{})
    oneAPI.code_typed(dummy, Tuple{})
    oneAPI.code_warntype(devnull, dummy, Tuple{})
    oneAPI.code_llvm(devnull, dummy, Tuple{})
    oneAPI.code_spirv(devnull, dummy, Tuple{})

    @device_code_lowered @oneapi dummy()
    @device_code_typed @oneapi dummy()
    @device_code_warntype io=devnull @oneapi dummy()
    @device_code_llvm io=devnull @oneapi dummy()
    @device_code_spirv io=devnull @oneapi dummy()

    mktempdir() do dir
        @device_code dir=dir @oneapi dummy()
    end

    @test_throws ErrorException @device_code_lowered nothing

    # make sure kernel name aliases are preserved in the generated code
    @test occursin("julia_dummy", sprint(io->(@device_code_llvm io=io optimize=false @oneapi dummy())))
    @test occursin("julia_dummy", sprint(io->(@device_code_llvm io=io @oneapi dummy())))
    @test occursin("julia_dummy", sprint(io->(@device_code_spirv io=io @oneapi dummy())))

    # make sure invalid kernels can be partially reflected upon
    let
        invalid_kernel() = throw()
        @test_throws oneAPI.KernelError @oneapi invalid_kernel()
        @test_throws oneAPI.KernelError @grab_output @device_code_warntype @oneapi invalid_kernel()
        out, err = @grab_output begin
            try
                @device_code_warntype @oneapi invalid_kernel()
            catch
            end
        end
        @test occursin("Body::Union{}", err)
    end

    let
        range_kernel() = (0.0:0.1:100.0; nothing)

        @test_throws oneAPI.InvalidIRError @oneapi range_kernel()
    end

    # set name of kernel
    @test occursin("julia_mykernel", sprint(io->(@device_code_llvm io=io begin
        k = zefunction(dummy, name="mykernel")
        k()
    end)))
end


@testset "external kernels" begin
    @eval module KernelModule
        export external_dummy
        external_dummy() = return
    end
    import ...KernelModule
    @oneapi KernelModule.external_dummy()
    @eval begin
        using ...KernelModule
        @oneapi external_dummy()
    end

    @eval module WrapperModule
        using oneAPI
        @eval dummy() = return
        wrapper() = @oneapi dummy()
    end
    WrapperModule.wrapper()
end


@testset "calling device function" begin
    @noinline child(i) = sink(i)
    function parent()
        child(1)
        return
    end

    @oneapi parent()
end


@testset "varargs" begin
    function kernel(args...)
        oneAPI.@print(args[2])
        return
    end

    _, out = @grab_output begin
        @oneapi kernel(1, 2, 3)
        synchronize()
    end
    @test out == "2"
end

end


############################################################################################

@testset "argument passing" begin

dims = (16, 16)
len = prod(dims)

@testset "manually allocated" begin
    function kernel(input, output)
        i = get_global_id(0)

        val = input[i]
        output[i] = val

        return
    end

    input = round.(rand(Float32, dims) * 100)
    output = similar(input)

    input_dev = oneArray(input)
    output_dev = oneArray(output)

    @oneapi items=len kernel(input_dev, output_dev)
    @test input ≈ Array(output_dev)
end


@testset "scalar through single-value array" begin
    function kernel(a, x)
        i = get_global_id(0)
        max = get_global_size(0)
        if i == max
            _val = a[i]
            x[] = _val
        end
        return
    end

    arr = round.(rand(Float32, dims) * 100)
    val = [0f0]

    arr_dev = oneArray(arr)
    val_dev = oneArray(val)

    @oneapi items=len kernel(arr_dev, val_dev)
    @test arr[dims...] ≈ Array(val_dev)[1]
end


@testset "scalar through single-value array, using device function" begin
    @noinline child(a, i) = a[i]
    function parent(a, x)
        i = get_global_id(0)
        max = get_global_size(0)
        if i == max
            _val = child(a, i)
            x[] = _val
        end
        return
    end

    arr = round.(rand(Float32, dims) * 100)
    val = [0f0]

    arr_dev = oneArray(arr)
    val_dev = oneArray(val)

    @oneapi items=len parent(arr_dev, val_dev)
    @test arr[dims...] ≈ Array(val_dev)[1]
end


@testset "tuples" begin
    # issue #7: tuples not passed by pointer

    function kernel(keeps, out)
        if keeps[1]
            out[] = 1
        else
            out[] = 2
        end
        return
    end

    keeps = (true,)
    d_out = oneArray(zeros(Int))

    @oneapi kernel(keeps, d_out)
    @test Array(d_out)[] == 1
end


@testset "ghost function parameters" begin
    # bug: ghost type function parameters are elided by the compiler

    len = 60
    a = rand(Float32, len)
    b = rand(Float32, len)
    c = similar(a)

    d_a = oneArray(a)
    d_b = oneArray(b)
    d_c = oneArray(c)

    @eval struct ExecGhost end

    function kernel(ghost, a, b, c)
        i = get_global_id(0)
        c[i] = a[i] + b[i]
        return
    end
    @oneapi items=len kernel(ExecGhost(), d_a, d_b, d_c)
    @test a+b == Array(d_c)


    # bug: ghost type function parameters confused aggregate type rewriting

    function kernel(ghost, out, aggregate)
        i = get_global_id(0)
        out[i] = aggregate[1]
        return
    end
    @oneapi items=len kernel(ExecGhost(), d_c, (42,))

    @test all(val->val==42, Array(d_c))
end


@testset "immutables" begin
    # issue #15: immutables not passed by pointer

    function kernel(ptr, b)
        ptr[] = imag(b)
        return
    end

    arr = oneArray(zeros(Float32))
    x = ComplexF32(2,2)

    @oneapi kernel(arr, x)
    @test Array(arr)[] == imag(x)
end


@testset "automatic recompilation" begin
    arr = oneArray(zeros(Int))

    function kernel(ptr)
        ptr[] = 1
        return
    end

    @oneapi kernel(arr)
    @test Array(arr)[] == 1

    function kernel(ptr)
        ptr[] = 2
        return
    end

    @oneapi kernel(arr)
    @test Array(arr)[] == 2
end


@testset "automatic recompilation (bis)" begin
    arr = oneArray(zeros(Int))

    @eval doit(ptr) = ptr[] = 1

    function kernel(ptr)
        doit(ptr)
        return
    end

    @oneapi kernel(arr)
    @test Array(arr)[] == 1

    @eval doit(ptr) = ptr[] = 2

    @oneapi kernel(arr)
    @test Array(arr)[] == 2
end


@testset "non-isbits arguments" begin
    function kernel1(T, i)
        sink(i)
        return
    end
    @oneapi kernel1(Int, 1)

    function kernel2(T, i)
        sink(unsafe_trunc(T,i))
        return
    end
    @oneapi kernel2(Int, 1.)
end


@testset "splatting" begin
    function kernel(out, a, b)
        out[] = a+b
        return
    end

    out = [0]
    out_dev = oneArray(out)

    @oneapi kernel(out_dev, 1, 2)
    @test Array(out_dev)[1] == 3

    all_splat = (out_dev, 3, 4)
    @oneapi kernel(all_splat...)
    @test Array(out_dev)[1] == 7

    partial_splat = (5, 6)
    @oneapi kernel(out_dev, partial_splat...)
    @test Array(out_dev)[1] == 11
end

@testset "object invoke" begin
    # this mimics what is generated by closure conversion

    @eval struct KernelObject{T} <: Function
        val::T
    end

    function (self::KernelObject)(a)
        a[] = self.val
        return
    end

    function outer(a, val)
       inner = KernelObject(val)
       @oneapi inner(a)
    end

    a = [1.]
    a_dev = oneArray(a)

    outer(a_dev, 2.)

    @test Array(a_dev) ≈ [2.]
end

@testset "closures" begin
    function outer(a_dev, val)
       function inner(a)
            # captures `val`
            a[] = val
            return
       end
       @oneapi inner(a_dev)
    end

    a = [1.]
    a_dev = oneArray(a)

    outer(a_dev, 2.)

    @test Array(a_dev) ≈ [2.]
end

@testset "conversions" begin
    @eval struct Host   end
    @eval struct Device end

    Adapt.adapt_storage(::oneAPI.KernelAdaptor, a::Host) = Device()

    Base.convert(::Type{Int}, ::Host)   = 1
    Base.convert(::Type{Int}, ::Device) = 2

    out = [0]

    # convert arguments
    out_dev = oneArray(out)
    let arg = Host()
        @test Array(out_dev) ≈ [0]
        function kernel(arg, out)
            out[] = convert(Int, arg)
            return
        end
        @oneapi kernel(arg, out_dev)
        @test Array(out_dev) ≈ [2]
    end

    # convert tuples
    out_dev = oneArray(out)
    let arg = (Host(),)
        @test Array(out_dev) ≈ [0]
        function kernel(arg, out)
            out[] = convert(Int, arg[1])
            return
        end
        @oneapi kernel(arg, out_dev)
        @test Array(out_dev) ≈ [2]
    end

    # convert named tuples
    out_dev = oneArray(out)
    let arg = (a=Host(),)
        @test Array(out_dev) ≈ [0]
        function kernel(arg, out)
            out[] = convert(Int, arg.a)
            return
        end
        @oneapi kernel(arg, out_dev)
        @test Array(out_dev) ≈ [2]
    end

    # don't convert structs
    out_dev = oneArray(out)
    @eval struct Nested
        a::Host
    end
    let arg = Nested(Host())
        @test Array(out_dev) ≈ [0]
        function kernel(arg, out)
            out[] = convert(Int, arg.a)
            return
        end
        @oneapi kernel(arg, out_dev)
        @test Array(out_dev) ≈ [1]
    end
end

@testset "argument count" begin
    val = [0]
    val_dev = oneArray(val)
    for i in (1, 10, 20, 34)
        variables = ('a':'z'..., 'A':'Z'...)
        params = [Symbol(variables[j]) for j in 1:i]
        # generate a kernel
        body = quote
            function kernel(arr, $(params...))
                arr[] = $(Expr(:call, :+, params...))
                return
            end
        end
        eval(body)
        args = [j for j in 1:i]
        call = Expr(:call, :kernel, val_dev, args...)
        cudacall = :(@oneapi $call)
        eval(cudacall)
        @test Array(val_dev)[1] == sum(args)
    end
end

@testset "keyword arguments" begin
    @eval inner_kwargf(foobar;foo=1, bar=2) = nothing

    @oneapi (()->inner_kwargf(42;foo=1,bar=2))()

    @oneapi (()->inner_kwargf(42))()

    @oneapi (()->inner_kwargf(42;foo=1))()

    @oneapi (()->inner_kwargf(42;bar=2))()

    @oneapi (()->inner_kwargf(42;bar=2,foo=1))()
end

@testset "captured values" begin
    function f(capture::T) where {T}
        function kernel(ptr)
            ptr[] = capture
            return
        end

        arr = oneArray(zeros(T))
        @oneapi kernel(arr)

        return Array(arr)[1]
    end

    using Test
    @test f(1) == 1
    @test f(2) == 2
end

end

############################################################################################

@testset "#55: invalid integers created by alloc_opt" begin
    function f(a)
        x = SVector(0f0, 0f0)
        v = MVector{3, Float32}(undef)
        for (i,_) in enumerate(x)
            v[i] = 1.0f0
        end
        a[1] = v[1]
        return nothing
    end
    @oneapi f(oneArray(zeros(1)))
end


############################################################################################

module FlowDiagnostics

export RichardsonNumber, RossbyNumber
export ErtelPotentialVorticity, ThermalWindPotentialVorticity
export IsotropicBuoyancyMixingRate, AnisotropicBuoyancyMixingRate
export IsotropicTracerVarianceDissipationRate, AnisotropicTracerVarianceDissipationRate

using Oceananigans
using Oceananigans.Operators
using Oceananigans.AbstractOperations
using Oceananigans.AbstractOperations: KernelFunctionOperation
using Oceananigans.Grids: Center, Face

# Some useful operators
@inline fψ²(i, j, k, grid, f, ψ) = @inbounds f(i, j, k, grid, ψ)^2


function RichardsonNumber(model; b=model.tracers.b, N²_bg=0, dUdz_bg=0, dVdz_bg=0)
    u, v, w = model.velocities

    dBdz_tot = ∂z(b) + N²_bg
    dUdz_tot = ∂z(u) + dUdz_bg
    dVdz_tot = ∂z(v) + dVdz_bg

    return dBdz_tot / (dUdz_tot^2 + dVdz_tot^2)
end


function RossbyNumber(model; dUdy_bg=0, dVdx_bg=0, f=nothing)
    u, v, w = model.velocities
    if f==nothing
        f = model.coriolis.f
    end

    dUdy_tot = ∂y(u) + dUdy_bg
    dVdx_tot = ∂x(v) + dVdx_bg

    return (dVdx_tot - dUdy_tot) / f
end



#++++ Potential vorticity
function potential_vorticity_in_thermal_wind_fff(i, j, k, grid, u, v, b, f)

    dVdx =  ℑzᵃᵃᶠ(i, j, k, grid, ∂xᶠᶠᵃ, v) # F, F, C → F, F, F
    dUdy =  ℑzᵃᵃᶠ(i, j, k, grid, ∂yᶠᶠᵃ, u) # F, F, C → F, F, F
    dbdz = ℑxyᶠᶠᵃ(i, j, k, grid, ∂zᵃᵃᶠ, b) # C, C, F → F, F, F

    pv_barot = (f + dVdx - dUdy) * dbdz

    dUdz = ℑyᵃᶠᵃ(i, j, k, grid, ∂zᵃᵃᶠ, u) # F, C, F → F, F, F
    dVdz = ℑxᶠᵃᵃ(i, j, k, grid, ∂zᵃᵃᶠ, v) # C, F, F → F, F, F

    pv_baroc = -f*(dUdz^2 + dVdz^2)

    return pv_barot + pv_baroc
end

function ThermalWindPotentialVorticity(model; f=nothing)
    u, v, w = model.velocities
    b = model.tracers.b
    if f==nothing
        f = model.coriolis.f
    end
    return KernelFunctionOperation{Face, Face, Face}(potential_vorticity_in_thermal_wind_fff, model.grid;
                                                     computed_dependencies=(u, v, w, b), parameters=f)
end


function ertel_potential_vorticity_fff(i, j, k, grid, u, v, w, b, params)

    dWdy =  ℑxᶠᵃᵃ(i, j, k, grid, ∂yᶜᶠᵃ, w) # C, C, F  → C, F, F  → F, F, F
    dVdz =  ℑxᶠᵃᵃ(i, j, k, grid, ∂zᵃᵃᶠ, v) # C, F, C  → C, F, F  → F, F, F
    dbdx = ℑyzᵃᶠᶠ(i, j, k, grid, ∂xᶠᶜᵃ, b) # C, C, C  → F, C, C  → F, F, F
    pv_x = (params.fx + dWdy - dVdz) * dbdx # F, F, F

    dUdz =  ℑyᵃᶠᵃ(i, j, k, grid, ∂zᵃᵃᶠ, u) # F, C, C  → F, C, F → F, F, F
    dWdx =  ℑyᵃᶠᵃ(i, j, k, grid, ∂xᶠᶜᵃ, w) # C, C, F  → F, C, F → F, F, F
    dbdy = ℑxzᶠᵃᶠ(i, j, k, grid, ∂yᶜᶠᵃ, b) # C, C, C  → C, F, C → F, F, F
    pv_y = (params.fy + dUdz - dWdx) * dbdy # F, F, F

    dVdx =  ℑzᵃᵃᶠ(i, j, k, grid, ∂xᶠᶠᵃ, v) # C, F, C  → F, F, C → F, F, F
    dUdy =  ℑzᵃᵃᶠ(i, j, k, grid, ∂yᶠᶠᵃ, u) # F, C, C  → F, F, C → F, F, F
    dbdz = ℑxyᶠᶠᵃ(i, j, k, grid, ∂zᵃᵃᶠ, b) # C, C, C  → C, C, F → F, F, F
    pv_z = (params.fz + dVdx - dUdy) * dbdz

    return pv_x + pv_y + pv_z
end

function ErtelPotentialVorticity(model; location = (Face, Face, Face))
    if location != (Face, Face, Face)
        throw(ArgumentError("ErtelPotentialVorticity only implemented at location (Face, Face, Face) for now."))
    end

    u, v, w = model.velocities
    if ~(model.background_fields.velocities.u isa Oceananigans.Fields.ZeroField)
        u += model.background_fields.velocities.u
    end
    if ~(model.background_fields.velocities.v isa Oceananigans.Fields.ZeroField)
        v += model.background_fields.velocities.v
    end
    if ~(model.background_fields.velocities.w isa Oceananigans.Fields.ZeroField)
        w += model.background_fields.velocities.w
    end

    b = model.tracers.b
    if ~(model.background_fields.tracers.b isa Oceananigans.Fields.ZeroField)
        b += model.background_fields.tracers.b
    end

    coriolis = model.coriolis
    if coriolis isa FPlane
        fx = fy = fz = model.coriolis.f
    elseif coriolis isa ConstantCartesianCoriolis
        fx = coriolis.fx
        fy = coriolis.fy
        fz = coriolis.fz
    else
        throw(ArgumentError("ErtelPotentialVorticity only implemented for FPlane and ConstantCartesianCoriolis"))
    end

    return KernelFunctionOperation{Face, Face, Face}(ertel_potential_vorticity_fff, model.grid;
                                                     computed_dependencies=(u, v, w, b), parameters=(; fx, fy, fz))
end
#----





#+++++ Tracer variance dissipation
function isotropic_tracer_variance_dissipation_rate_ccc(i, j, k, grid, b, κᵇ)
    dbdx² = ℑxᶜᵃᵃ(i, j, k, grid, fψ², ∂xᶠᵃᵃ, b) # C, C, C  → F, C, C  → C, C, C
    dbdy² = ℑyᵃᶜᵃ(i, j, k, grid, fψ², ∂yᵃᶠᵃ, b) # C, C, C  → C, F, C  → C, C, C
    dbdz² = ℑzᵃᵃᶜ(i, j, k, grid, fψ², ∂zᵃᵃᶠ, b) # C, C, C  → C, C, F  → C, C, C

    return 2 * κᵇ[i,j,k] * (dbdx² + dbdy² + dbdz²)
end
function IsotropicTracerVarianceDissipationRate(model, b, κᵇ; location = (Center, Center, Center))
    if location == (Center, Center, Center)
        return KernelFunctionOperation{Center, Center, Center}(isotropic_tracer_variance_dissipation_rate_ccc, model.grid;
                                       computed_dependencies=(b, κᵇ))
    else
        throw(Exception)
    end
end


function anisotropic_tracer_variance_dissipation_rate_ccc(i, j, k, grid, b, params)
    dbdx² = ℑxᶜᵃᵃ(i, j, k, grid, fψ², ∂xᶠᵃᵃ, b) # C, C, C  → F, C, C  → C, C, C
    dbdy² = ℑyᵃᶜᵃ(i, j, k, grid, fψ², ∂yᵃᶠᵃ, b) # C, C, C  → C, F, C  → C, C, C
    dbdz² = ℑzᵃᵃᶜ(i, j, k, grid, fψ², ∂zᵃᵃᶠ, b) # C, C, C  → C, C, F  → C, C, C

    return 2 * (params.κx*dbdx² + params.κy*dbdy² + params.κz*dbdz²)
end
function AnisotropicTracerVarianceDissipationRate(model, b, κx, κy, κz; location = (Center, Center, Center))
    if location == (Center, Center, Center)
        return KernelFunctionOperation{Center, Center, Center}(anisotropic_tracer_variance_dissipation_rate_ccc, model.grid;
                                       computed_dependencies=(b,), 
                                       parameters=(κx=κx, κy=κy, κz=κz),)
    else
        throw(Exception)
    end
end
#-----

end # module

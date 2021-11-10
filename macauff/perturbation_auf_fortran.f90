! Licensed under a 3-clause BSD style license - see LICENSE

module perturbation_auf_fortran
! This module provides the Fortran code for the handling of the creation of perturbation
! component of the Astrometric Uncertainty Function.

implicit none

integer, parameter :: dp = kind(0.0d0)  ! double precision
real(dp), parameter :: pi = 4.0_dp*atan(1.0_dp)

contains

subroutine get_density(a_ax1, a_ax2, b_ax1, b_ax2, maxdist, counts)
    ! Calculate the number of sources in a given catalogue within a specified radius of each source.
    integer, parameter :: dp = kind(0.0d0)  ! double precision
    ! Sky coordinates for catalogues a and b.
    real(dp), intent(in) :: a_ax1(:), a_ax2(:), b_ax1(:), b_ax2(:)
    ! Separation to consider the number of objects within.
    real(dp), intent(in) :: maxdist
    ! Number of objects within maxdist of each catalogue a source.
    integer, intent(out) :: counts(size(a_ax1))
    ! Loop counters.
    integer :: i, j
    ! Sky separations.
    real(dp) :: dist, dx, d_ax1, d_ax2

    counts = 0
!$OMP PARALLEL DO DEFAULT(NONE) PRIVATE(i, j, dist, dx, d_ax1, d_ax2) SHARED(a_ax1, a_ax2, b_ax1, b_ax2, counts, maxdist)
    do j = 1, size(a_ax1)
        do i = 1, size(b_ax1)
            ! Difference in latitude is always just the absolute difference
            d_ax2 = abs(a_ax2(j) - b_ax2(i))
            if (d_ax2 <= maxdist) then
                ! Need reduction of Haversine formula for longitude difference, remembering to convert to degrees:
                d_ax1 = 2.0_dp * asin(abs(cos(a_ax2(j) / 180.0_dp * pi) * &
                                      sin((a_ax1(j) - b_ax1(i))/2.0_dp / 180.0_dp * pi))) * 180.0_dp / pi
                if (d_ax1 <= maxdist) then
                    call haversine(a_ax1(j), b_ax1(i), a_ax2(j), b_ax2(i), dist)
                    if (dist <= maxdist) then
                        counts(j) = counts(j) + 1
                    end if
                end if
            end if
        end do
    end do
!$OMP END PARALLEL DO

end subroutine get_density

subroutine get_circle_area_overlap(cat_ax1, cat_ax2, density_radius, min_lon, max_lon, min_lat, max_lat, circ_overlap_area)
    integer, parameter :: dp = kind(0.0d0)  ! double precision
    real(dp), intent(in) :: cat_ax1(:), cat_ax2(:), density_radius, min_lon, max_lon, min_lat, max_lat
    real(dp), intent(out) :: circ_overlap_area(size(cat_ax1))

    integer :: i, j, has_overlapped_edge(4)
    real(dp) :: area, edges(4), coords(4), h, a, b, chord_area_overlap, a_eval, b_eval

    edges = (/ min_lon, min_lat, max_lon, max_lat /)
!$OMP PARALLEL DO DEFAULT(NONE) PRIVATE(i, j, area, has_overlapped_edge, coords, h, a, b, a_eval, b_eval, chord_area_overlap) &
!$OMP& SHARED(density_radius, cat_ax1, cat_ax2, edges, circ_overlap_area, min_lon, max_lon, min_lat, max_lat)
    do j = 1, size(cat_ax1)
        area = pi * density_radius**2
        has_overlapped_edge = (/ 0, 0, 0, 0 /)

        coords = (/ cat_ax1(j), cat_ax2(j), cat_ax1(j), cat_ax2(j) /)
        do i = 1, 4
            h = abs(coords(i) - edges(i))
            if (h < density_radius) then
                ! The first chord integration is "free", and does not have
                ! truncated limits based on overlaps; the final chord integration,
                ! however, cares about truncation on both sides. The "middle two"
                ! integrations only truncate to the previous side.
                a = -1.0_dp * sqrt(density_radius**2 - h**2)
                b = sqrt(density_radius**2 - h**2)
                if (i == 2 .and. has_overlapped_edge(1) == 1) then
                    a = max(a, min_lon - coords(1))
                end if
                if (i == 3 .and. has_overlapped_edge(2) == 1) then
                    a = max(a, min_lat - coords(2))
                end if
                if (i == 4 .and. has_overlapped_edge(1) == 1) then
                    a = max(a, min_lon - coords(1))
                end if
                if (i == 4 .and. has_overlapped_edge(3) == 1) then
                    b = min(b, max_lon - coords(1))
                end if

                call chord_integral_eval(a, density_radius, h, a_eval)
                call chord_integral_eval(b, density_radius, h, b_eval)
                chord_area_overlap = b_eval - a_eval
                has_overlapped_edge(i) = 1

                area = area - chord_area_overlap
            end if
        end do
        circ_overlap_area(j) = area
    end do
!$OMP END PARALLEL DO

end subroutine get_circle_area_overlap

subroutine chord_integral_eval(x, r, h, integral)
    integer, parameter :: dp = kind(0.0d0)  ! double precision
    real(dp), intent(in) :: x, r, h
    real(dp), intent(out) :: integral
    real(dp) :: d

    d = sqrt(r**2 - x**2)

    if (d <= 1e-7) then
        ! If d is zero, x / d is +-infinity (depending on sign of x) and arctan(+-infinity) = +-pi/2
        integral = 0.5_dp * (x * d + r**2 * sign(1.0_dp, x) * pi / 2.0_dp) - h * x
    else
        integral = 0.5_dp * (x * d + r**2 * atan(x / d)) - h * x
    end if

end subroutine chord_integral_eval

subroutine perturb_aufs(Narray, magarray, r, dr, rbins, j0s, mag_D, dmag_D, Ds, N_norm, num_int, dmcut, psfr, &
    lentrials, seed, Fracgrid, Fluxav, fouriergrid, rgrid, intrgrid)
    ! Fortran wrapper for the perturbation AUF component calculation for a set of density-magnitude
    ! combinations, creating the various parameters needed to use the distribution of perturbations.
    integer, parameter :: dp = kind(0.0d0)  ! double precision
    ! Number of simulated PSFs to generate.
    integer, intent(in) :: lentrials
    ! Number of bins to draw simulated perturbers from, below the brightness of the central source.
    integer, intent(in) :: num_int(:)
    ! RNG seed.
    integer, intent(in) :: seed(:, :)
    ! Arrays of local densities and central source brightnesses to generate simulated PSFs for.
    real(dp), intent(in) :: Narray(:), magarray(:)
    ! Real space coordinates: middle of bins, bin widths, and bin edges (hence size(r)+1 == size(rbins)).
    real(dp), intent(in) :: r(:), dr(:), rbins(:)
    ! Bessel Function of First Kind of Zeroth Order, evaluated at various r-rho combinations.
    real(dp), intent(in) :: j0s(:, :)
    ! Magnitudes, magnitude bin widths, and logarithmic source number densities, from which to draw
    ! Poissonian average sources per PSF circle.
    real(dp), intent(in) :: mag_D(:), dmag_D(:), Ds(:)
    ! Normalising density of simulated sources.
    real(dp), intent(in) :: N_norm
    ! Relative fluxes, in magnitude offset, above which to record whether a central object suffers
    ! a contaminating source or not.
    real(dp), intent(in) :: dmcut(:)
    ! Radius of PSF for given filter, used to define the PSF circle inside which to draw contaminants.
    real(dp), intent(in) :: psfr
    ! Fraction of sources with contaminant above dmcut, and average contamination of, density-magnitude
    ! combinations to consider for this filter-sightline pair.
    real(dp), intent(out) :: Fracgrid(size(dmcut), size(Narray)), Fluxav(size(Narray))
    ! Fourier, real, and cumulative integral of real, representations of the distribution of perturbations
    ! simulated for the lentrials number of PSFs.
    real(dp), intent(out) :: fouriergrid(size(j0s, 2), size(Narray)), rgrid(size(r), size(Narray)), intrgrid(size(r), size(Narray))
    ! Loop counters.
    integer :: j, k
    ! Variables to define the sizes and positions of various arrays: defines allocatable length of dm;
    ! position in mag_D; and maximum number of simulated perturbers in a single PSF.
    integer :: lendm, mag_Dindex, maxk
    ! Temporary storage of various parameters: individual perturbations of a given density-brightness
    ! combination, fractions of PSF realisations for one N-m pair that have contaminants above dmcut
    ! relative fluxes, and the average flux within each PSF realisation for the given PSF setup.
    real(dp) :: offsets(lentrials), fraccontam(size(dmcut)), fluxcontam(lentrials)
    ! Individual PSF setup distribution functions: histogram of perturbations, cumulative integral of
    ! perturbations, and Fourier-space representation of perturbation distribution.
    real(dp) :: hist(size(r)), cumulathist(size(r)), fourierhist(size(j0s, 2))
    ! Central source magnitude and local normalising density at which to simulate PSF contaminations.
    real(dp) :: mag, N_b, midr(size(r))
    ! Define the number of sources per PSF circle in each magnitude bin range (from central source
    ! brightness to num_int bins fainter), the magnitude offsets (relative fluxes) of those bins,
    ! and the widths of those magnitude offset bins.
    real(dp), allocatable :: dNs(:), dms(:), ddms(:)

!$OMP PARALLEL DO DEFAULT(NONE) PRIVATE(j, k, N_b, mag, mag_Dindex, lendm, dms, dNs, ddms, offsets, fraccontam, maxk, &
!$OMP& fluxcontam, hist, cumulathist, fourierhist, midr) &
!$OMP& SHARED(Narray, magarray, mag_D, psfr, dmcut, lentrials, num_int, Ds, dmag_D, N_norm, rbins, r, dr, j0s, rgrid, &
!$OMP& seed, fouriergrid, intrgrid, Fracgrid, Fluxav) SCHEDULE(guided)
    do j = 1, size(Narray)
        N_b = Narray(j)
        mag = magarray(j)
        mag_Dindex = minloc(mag_D, mask=(mag_D >= mag), dim=1)
        lendm = min(num_int(j), size(mag_D)-mag_Dindex+1)
        allocate(dms(lendm))
        allocate(ddms(lendm))
        allocate(dNs(lendm))
        do k = 1, lendm
            dNs(k) = 10**Ds(mag_Dindex+k-1) * dmag_D(mag_Dindex+k-1) * pi * (psfr/3600.0_dp)**2 * N_b / N_norm
            dms(k) = mag_D(mag_Dindex+k-1) - mag
            ddms(k) = dmag_D(mag_Dindex+k-1)
        end do
        maxk = max(5, int(10*maxval(dNs)))
        call scatter_perturbers(dNs, dms, psfr, maxk, dmcut, offsets, fraccontam, fluxcontam, ddms, lentrials, seed(:, j))
        call histogram1d_dp(offsets, rbins(1), rbins(size(rbins)), size(r), midr, hist)

        ! r is middle of bins, which are represented by rbins; there's a shift of dr/2 between the two (minus rbins(lenr+1))
        hist = hist / (pi * ((r + dr/2.0_dp)**2 - (r - dr/2.0_dp)**2) * sum(hist))
        cumulathist(1) = hist(1) * pi * ((r(1) + dr(1)/2.0_dp)**2 - (r(1) - dr(1)/2.0_dp)**2)
        do k = 2, size(r)
            cumulathist(k) = cumulathist(k-1) + hist(k) * pi * ((r(k) + dr(k)/2.0_dp)**2 - (r(k) - dr(k)/2.0_dp)**2)  
        end do
        call fourier_transform(hist, r, dr, j0s, fourierhist)
        fouriergrid(:, j) = fourierhist
        rgrid(:, j) = hist

        intrgrid(:, j) = cumulathist
        Fracgrid(:, j) = fraccontam
        Fluxav(j) = sum(fluxcontam) / real(lentrials, dp)

        deallocate(dms)
        deallocate(ddms)
        deallocate(dNs)
    end do
!$OMP END PARALLEL DO

end subroutine perturb_aufs

subroutine scatter_perturbers(dNs, dms, psfr, maxk, dmcut, offsets, fraccontam, fluxcontam, ddms, lentrials, seed)
    ! Given a set of average numbers of sources per PSF circle for a series of relative fluxes, populate
    ! a bright, central source's PSF with randomly placed sources, and calculate the flux brightening
    ! and expected PSF centroid shift.
    integer, parameter :: dp = kind(0.0d0)  ! double precision
    ! Number of simulated PSFs to generate.
    integer, intent(in) :: lentrials
    ! Maximum allowed number of sources of a given magnitude offset in a PSF circle.
    integer, intent(in) :: maxk
    ! RNG seed.
    integer, intent(in) :: seed(:)
    ! Average numbers of sources per PSF circle for each magnitude offset; magnitude offsets (or
    ! relative fluxes) to be populated within the PSF, and the bin width of the magnitude offsets.
    real(dp), intent(in) :: dNs(:), dms(:), ddms(:)
    ! PSF radius, defined by the Rayleigh criterion based on the full-width at half-maximum.
    real(dp), intent(in) :: psfr
    ! Magnitude offsets above which to consider if a PSF has been contaminated by a source of
    ! this relative flux.
    real(dp), intent(in) :: dmcut(:)

    real(dp), intent(out) :: offsets(lentrials), fraccontam(size(dmcut)), fluxcontam(lentrials)
    ! Loop counters, and number of sources to be populated within a given PSF for a small dm slice.
    integer :: i, j, k, loopk
    ! Flag to indicate whether each PSF realisation has been contaminated by a source brighter
    ! than each dmcut relative flux.
    integer :: ncontams(size(dmcut), lentrials)
    ! Variables related to position within the PSF circle for each object in a dm slice.
    real(dp) :: x(maxk), y(maxk), xav, yav, t(maxk), r(maxk)
    ! Poissonian-related values, defining the randomly drawn number of small magnitude range objects
    ! in a given PSF.
    real(dp) :: factorial(maxk+1), powercounter, numchance, expdns(size(dNs)), cumulativepoisson(maxk+1, size(dNs))
    ! Variables related to the relative flux of each simulated perturbing source, and the total flux
    ! within a PSF.
    real(dp) :: fluxes(size(dNs)), dfluxes(2, size(dNs)), df(maxk), f0, normf

    factorial(1) = 1.0_dp
    do i = 1, maxk
        factorial(i+1) = factorial(i) * real(i, dp)
    end do

    call random_seed(put=seed)

    fluxes = 10**(-dms/2.5_dp)
    ! Asymmetric bins in flux space (for symmetric mag bins) needs an upper and lower bin width
    dfluxes(1, :) = 10**(-(dms-ddms/2.0_dp)/2.5_dp) - 10**(-dms/2.5_dp)
    dfluxes(2, :) = 10**(-dms/2.5_dp) - 10**(-(dms+ddms/2.0_dp)/2.5_dp)
    expdns = exp(-dNs)

    ncontams = 0
    offsets = 0.0_dp
    fluxcontam = 0.0_dp
    ! Cumulative poisson = exp(-l) sum_i=0^floor(k) l^i / i!; l^0 / 0! = 1
    cumulativepoisson(1, :) = 1.0_dp
    do j = 1, size(dNs)
        powercounter = dNs(j)
        do k = 1, maxk
            cumulativepoisson(k+1, j) = cumulativepoisson(k, j) + powercounter / factorial(k+1) 
            powercounter = powercounter * dNs(j)
        end do
    end do
    do i = 1, lentrials
        xav = 0.0_dp
        yav = 0.0_dp
        normf = 1.0_dp
        do j = 1, size(dNs)
            call random_number(numchance)
            numchance = numchance / expdns(j)
            if (cumulativepoisson(1, j) > numchance) then
                loopk = 0
            else
                if (cumulativepoisson(maxk, j) < numchance) then
                    loopk = maxk
                else
                    loopk = maxk
                    do k = 1, maxk
                        if (cumulativepoisson(k+1, j) > numchance) then
                            loopk = k
                            exit
                        end if
                    end do
                end if
                do k = 1, size(dmcut)
                    if (ncontams(k, i) == 0 .and. dms(j) < dmcut(k)) then
                        ncontams(k, i) = 1
                    end if
                end do
                call random_number(t(:loopk))
                call random_number(r(:loopk))
                call random_number(df(:loopk))
                t(:loopk) = t(:loopk) * 2.0_dp * pi
                r(:loopk) = sqrt(r(:loopk)) * psfr

                ! fluxes is middle of bin
                df(:loopk) = df(:loopk) * (dfluxes(1, j) + dfluxes(2, j))
                f0 = fluxes(j) - dfluxes(2, j)

                x(:loopk) = r(:loopk) * sin(t(:loopk))
                y(:loopk) = r(:loopk) * cos(t(:loopk))

                xav = xav + sum(x(:loopk) * (f0+df(:loopk)))
                yav = yav + sum(y(:loopk) * (f0+df(:loopk)))
                normf = normf + sum(f0+df(:loopk))
            end if
        end do
        xav = xav / normf
        yav = yav / normf
        offsets(i) = sqrt(xav**2 + yav**2)
        fluxcontam(i) = normf - 1.0_dp
    end do
    ! TODO: update with mean/median/model/percentiles
    do k = 1, size(dmcut)
        fraccontam(k) = real(sum(ncontams(k, :)), dp) / real(lentrials, dp)
    end do

end subroutine scatter_perturbers

! ------------------------------------------------------------------------------
! Copyright (c) 2009-13, Thomas P. Robitaille
!
! All rights reserved.
!
! Redistribution and use in source and binary forms, with or without
! modification, are permitted provided that the following conditions are met:
!
!  * Redistributions of source code must retain the above copyright notice, this
!    list of conditions and the following disclaimer.
!
!  * Redistributions in binary form must reproduce the above copyright notice,
!    this list of conditions and the following disclaimer in the documentation
!    and/or other materials provided with the distribution.
!
! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
! AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
! IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
! DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
! FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
! DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
! SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
! CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
! OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
! OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
! ------------------------------------------------------------------------------
! (Applies to xval_dp, ipos_dp, and histogram1d_dp)

real(dp) function xval_dp(xmin,xmax,i,nbin)
  ! Find central value of a bin for a regular histogram

  integer, parameter :: dp = kind(0.0d0)  ! double precision

  real(dp),intent(in) :: xmin,xmax
  ! range of values

  integer,intent(in) :: i
  ! the bin number

  integer,intent(in) :: nbin
  ! number of bins

  real(dp) :: frac

  frac=(real(i-1)+0.5)/real(nbin)

  xval_dp=frac*(xmax-xmin)+xmin

end function xval_dp

integer function ipos_dp(xmin,xmax,x,nbin)
! Find bin a value falls in for a regular histogram

    integer, parameter :: dp = kind(0.0d0)  ! double precision

    real(dp),intent(in) :: xmin,xmax
    ! range of values

    real(dp),intent(in) :: x
    ! the value to bin

    integer,intent(in) :: nbin
    ! number of bins

    real(dp) :: frac

    if(xmax > xmin) then

       if(x < xmin) then
          ipos_dp = 0
       else if(x > xmax) then
          ipos_dp = nbin+1
       else if(x < xmax) then
          frac=(x-xmin)/(xmax-xmin)
          ipos_dp=int(frac*real(nbin, dp))+1
       else  ! x == xmax
          ipos_dp = nbin
       end if

    else

       if(x < xmax) then
          ipos_dp = 0
       else if(x > xmin) then
          ipos_dp = nbin+1
       else if(x < xmin) then
          frac=(x-xmin)/(xmax-xmin)
          ipos_dp=int(frac*real(nbin, dp))+1
       else  ! x == xmin
          ipos_dp = nbin
       end if

    end if

end function ipos_dp

subroutine histogram1d_dp(array,xmin,xmax,nbin,hist_x,hist_y,mask,weights)
  ! Bin 1D array of values into 1D regular histogram

  integer, parameter :: dp = kind(0.0d0)  ! double precision

  real(dp),dimension(:),intent(in) :: array
  real(dp),dimension(:),intent(in),optional :: weights
  ! the array of values to bin

  real(dp),intent(in) :: xmin,xmax
  ! the range of the histogram

  integer,intent(in) :: nbin
  ! number of bins

  real(dp),dimension(nbin),intent(out) :: hist_x,hist_y
  ! the histogram

  integer :: i,ibin
  ! binning variables

  logical,optional,intent(in) :: mask(:)
  logical,allocatable:: keep(:)

  allocate(keep(size(array)))

  if(present(mask)) then
     keep = mask
  else
     keep = .true.
  end if

  hist_x=0._dp ; hist_y=0._dp

  do i=1,size(array)
     if(keep(i)) then
        ibin=ipos_dp(xmin,xmax,array(i),nbin)
        if(ibin.ge.1.and.ibin.le.nbin) then
           if(present(weights)) then
              hist_y(ibin)=hist_y(ibin)+weights(i)
           else
              hist_y(ibin)=hist_y(ibin)+1._dp
           end if
        end if
     end if
  end do

  do ibin=1,nbin
     hist_x(ibin)=xval_dp(xmin,xmax,ibin,nbin)
  end do

  deallocate(keep)

end subroutine histogram1d_dp

subroutine fourier_transform(pr, r, dr, j0s, G)
    ! Calculates the Fourier-Bessel transform, or Hankel transform of zeroth order, of a function.
    ! This is equivalent to a two-dimensional Fourier transform in the limiting case of circular
    ! symmetry.
    integer, parameter :: dp = kind(0.0d0)  ! double precision
    ! Function to be fourier transformed, in units of per area.
    real(dp), intent(in) :: pr(:)
    ! Real space coordinates and bin widths.
    real(dp), intent(in) :: r(:), dr(:)
    ! Bessel function of first kind of zeroth order, evaluated at 2 * pi * r * rho, where rho
    ! is the fourier space coordinates of interest to capture the fourier transformation.
    real(dp), intent(in) :: j0s(:, :)
    ! The Fourier-Bessel transform of pr, evaluated at the appropriate fourier space coordinates
    ! rho, as desired.
    real(dp), intent(out) :: G(size(j0s, 2))
    ! Loop counters.
    integer :: i, j
    G(:) = 0.0_dp
    ! Following notation of J. W. Goodman, Introduction to Fourier Optics (1996), equation 2-31,
    ! G0 is the Hankel transform of gR, and the inverse is the opposite.
    ! For a Hankel transform (of zero order; or Fourier-Bessel transform) the "r" variable is r, with
    ! rho along the other axis of j0s, but for an inverse transformation "r" becomes rho with r
    ! represented along the second axis of j0s, because the two transformations are symmetric.
    
    do i = 1, size(j0s, 2)
        do j = 1, size(j0s, 1)
            G(i) = G(i) + r(j) * pr(j) * j0s(j, i) * dr(j)
        end do
        G(i) = G(i) * 2.0_dp * pi
    end do

end subroutine fourier_transform

subroutine get_random_seed_size(size)
    ! Number of initial seeds expected by random_seed, to be initialised for a specified RNG setup.
    integer, intent(out) :: size

    call random_seed(size=size)

end subroutine get_random_seed_size

end module perturbation_auf_fortran
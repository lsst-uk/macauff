# Licensed under a 3-clause BSD style license - see LICENSE
'''
Tests for the "fit_astrometry" module.
'''


import pytest
import numpy as np
from numpy.testing import assert_allclose
import os

from ..fit_astrometry import AstrometricCorrections


class TestAstroCorrection:
    def setup_method(self):
        self.rng = np.random.default_rng(seed=43578345)
        self.N = 5000
        choice = self.rng.choice(self.N, size=self.N, replace=False)
        self.true_ra = np.linspace(100, 110, self.N)[choice]
        self.true_dec = np.linspace(-3, 3, self.N)[choice]

        os.makedirs('store_data', exist_ok=True)

        os.makedirs('tri_folder', exist_ok=True)
        # Fake some TRILEGAL downloads with random data.
        text = ('#area = 4.0 sq deg\n#Av at infinity = 0\n' +
                'Gc logAge [M/H] m_ini   logL   logTe logg  m-M0   Av    ' +
                'm2/m1 mbol   J      H      Ks     IRAC_3.6 IRAC_4.5 IRAC_5.8 IRAC_8.0 MIPS_24 ' +
                'MIPS_70 MIPS_160 W1     W2     W3     W4       Mact\n')
        w1s = self.rng.uniform(14, 16, size=1000)
        for w1 in w1s:
            text = text + (
                '1   6.65 -0.39  0.02415 -2.701 3.397  4.057 14.00  8.354 0.00 25.523 25.839 ' +
                '24.409 23.524 22.583 22.387 22.292 22.015 21.144 19.380 20.878 '
                '{} 22.391 21.637 21.342  0.024\n '.format(w1))
        with open('tri_folder/trilegal_sim_105.0_0.0_bright.dat', "w") as f:
            f.write(text)
        with open('tri_folder/trilegal_sim_105.0_0.0_faint.dat', "w") as f:
            f.write(text)

    def fake_cata_cutout(self, lmin, lmax, bmin, bmax, *cat_args):
        astro_uncert = self.rng.uniform(0.001, 0.002, size=self.N)
        mag = self.rng.uniform(12, 12.1, size=self.N)
        mag_uncert = self.rng.uniform(0.01, 0.02, size=self.N)
        a = np.array([self.true_ra, self.true_dec, astro_uncert, mag, mag_uncert]).T
        if self.npy_or_csv == 'npy':
            np.save(self.a_cat_name.format(*cat_args), a)
        else:
            np.savetxt(self.a_cat_name.format(*cat_args), a, delimiter=',')

    def fake_catb_cutout(self, lmin, lmax, bmin, bmax, *cat_args):
        mag = np.empty(self.N, float)
        # Fake some data to plot SNR(S) = S / sqrt(c S + b (aS)^2)
        mag[:50] = np.linspace(10, 18, 50)
        mag[50:100] = mag[:50] + self.rng.uniform(-0.0001, 0.0001, size=50)
        s = 10**(-1/2.5 * mag[:50])
        snr = s / np.sqrt(3.5e-16 * s + 8e-17 + (1.2e-2 * s)**2)
        mag_uncert = np.empty(self.N, float)
        mag_uncert[:50] = 2.5 * np.log10(1 + 1/snr)
        mag_uncert[50:100] = mag_uncert[:50] + self.rng.uniform(-0.001, 0.001, size=50)
        astro_uncert = np.empty(self.N, float)
        astro_uncert[:100] = 0.01
        # Divide the N-100 objects at the 0/21/44/70/100 interval, for a
        # 21/23/26/31 split.
        i_list = [100, int((self.N-100)*0.21 + 100),
                  int((self.N-100)*0.44 + 100), int((self.N-100)*0.7 + 100)]
        j_list = [i_list[1], i_list[2], i_list[3], self.N]
        for i, j, mag_mid, sig_mid in zip(i_list, j_list,
                                          [14.07, 14.17, 14.27, 14.37], [0.05, 0.075, 0.1, 0.12]):
            mag[i:j] = self.rng.uniform(mag_mid-0.05, mag_mid+0.05, size=j-i)
            snr_mag = mag_mid / np.sqrt(3.5e-16 * mag_mid + 8e-17 + (1.2e-2 * mag_mid)**2)
            dm_mag = 2.5 * np.log10(1 + 1/snr_mag)
            mag_uncert[i:j] = self.rng.uniform(dm_mag-0.005, dm_mag+0.005, size=j-i)
            astro_uncert[i:j] = self.rng.uniform(sig_mid, sig_mid+0.01, size=j-i)
        angle = self.rng.uniform(0, 2*np.pi, size=self.N)
        ra_angle, dec_angle = np.cos(angle), np.sin(angle)
        # Key is that objects are distributed over TWICE their quoted uncertainty!
        # Also remember that uncertainty needs to be in arcseconds but
        # offset in deg.
        dist = self.rng.rayleigh(scale=2*astro_uncert / 3600, size=self.N)
        rand_ra = self.true_ra + dist * ra_angle
        rand_dec = self.true_dec + dist * dec_angle
        b = np.array([rand_ra, rand_dec, astro_uncert, mag, mag_uncert]).T
        if self.npy_or_csv == 'npy':
            np.save(self.b_cat_name.format(*cat_args), b)
        else:
            np.savetxt(self.b_cat_name.format(*cat_args), b, delimiter=',')

    def test_fit_astrometry_load_errors(self):
        dd_params = np.load(os.path.join(os.path.dirname(__file__), 'data/dd_params.npy'))
        l_cut = np.load(os.path.join(os.path.dirname(__file__), 'data/l_cut.npy'))
        ax1_mids, ax2_mids = np.array([105], dtype=float), np.array([0], dtype=float)
        magarray = np.array([14.07, 14.17, 14.27, 14.37])
        magslice = np.array([0.05, 0.05, 0.05, 0.05])
        sigslice = np.array([0.1, 0.1, 0.1, 0.1])

        _kwargs = {
            'psf_fwhm': 6.1, 'numtrials': 10000, 'nn_radius': 30, 'dens_search_radius': 900,
            'save_folder': 'ac_save_folder', 'trifolder': 'tri_folder', 'triname': 'trilegal_sim',
            'maglim_b': 13, 'maglim_f': 25, 'magnum': 11, 'trifilterset': '2mass_spitzer_wise',
            'trifiltname': 'W1', 'gal_wav_micron': 3.35, 'gal_ab_offset': 2.699,
            'gal_filtname': 'wise2010-W1', 'gal_alav': 0.039, 'bright_mag': 16, 'dm': 0.1,
            'dd_params': dd_params, 'l_cut': l_cut, 'ax1_mids': ax1_mids, 'ax2_mids': ax2_mids,
            'cutout_area': 60, 'cutout_height': 6, 'mag_array': magarray, 'mag_slice': magslice,
            'sig_slice': sigslice, 'n_pool': 1, 'pos_and_err_indices': [[0, 1, 2], [0, 1, 2]],
            'mag_indices': [3], 'mag_unc_indices': [4], 'mag_names': ['W1'], 'best_mag_index': 0}

        with pytest.raises(ValueError, match='single_sided_auf must be True.'):
            AstrometricCorrections(
                **_kwargs, single_sided_auf=False, ax_dimension=1, npy_or_csv='npy',
                coord_or_chunk='coord', coord_system='equatorial', pregenerate_cutouts=True)
        for ax_dim in [3, 'A']:
            with pytest.raises(ValueError, match="ax_dimension must either be '1' or "):
                AstrometricCorrections(
                    **_kwargs, ax_dimension=ax_dim, npy_or_csv='npy',
                    coord_or_chunk='coord', coord_system='equatorial', pregenerate_cutouts=True)
        for n_or_c in ['x', 4, 'npys']:
            with pytest.raises(ValueError, match="npy_or_csv must either be 'npy' or"):
                AstrometricCorrections(
                    **_kwargs, ax_dimension=1, npy_or_csv=n_or_c,
                    coord_or_chunk='coord', coord_system='equatorial', pregenerate_cutouts=True)
        for c_or_c in ['x', 4, 'npys']:
            with pytest.raises(ValueError, match="coord_or_chunk must either be 'coord' or"):
                AstrometricCorrections(
                    **_kwargs, ax_dimension=1, npy_or_csv='csv',
                    coord_or_chunk=c_or_c, coord_system='equatorial', pregenerate_cutouts=True)
        with pytest.raises(ValueError, match="chunks must be provided"):
            AstrometricCorrections(
                **_kwargs, ax_dimension=1, npy_or_csv='csv',
                coord_or_chunk='chunk', coord_system='equatorial', pregenerate_cutouts=True)
        with pytest.raises(ValueError, match="ax_dimension must be 2, and ax1-ax2 pairings "):
            AstrometricCorrections(
                **_kwargs, ax_dimension=1, npy_or_csv='csv', pregenerate_cutouts=True,
                coord_or_chunk='chunk', coord_system='equatorial', chunks=[2017])
        with pytest.raises(ValueError, match="ax1_mids, ax2_mids, and chunks must all be the "):
            AstrometricCorrections(
                **_kwargs, ax_dimension=2, npy_or_csv='csv', pregenerate_cutouts=True,
                coord_or_chunk='chunk', coord_system='equatorial', chunks=[2017, 2018])
        for e_or_g in ['x', 4, 'galacticorial']:
            with pytest.raises(ValueError, match="coord_system must either be 'equatorial'"):
                AstrometricCorrections(
                    **_kwargs, ax_dimension=1, npy_or_csv='csv',
                    coord_or_chunk='coord', coord_system=e_or_g, pregenerate_cutouts=True)
        for pregen_cut in [2, 'x', 'true']:
            with pytest.raises(ValueError, match="pregenerate_cutouts should either be 'True' or "):
                AstrometricCorrections(
                    **_kwargs, ax_dimension=1, npy_or_csv='csv', pregenerate_cutouts=pregen_cut,
                    coord_or_chunk='coord', coord_system='equatorial')
        del _kwargs['cutout_height']
        with pytest.raises(ValueError, match="cutout_height must be given if pregenerate_cutouts"):
            AstrometricCorrections(
                **_kwargs, ax_dimension=1, npy_or_csv='csv', pregenerate_cutouts=False,
                coord_or_chunk='coord', coord_system='equatorial')
        del _kwargs['cutout_area']
        with pytest.raises(ValueError, match="cutout_area must be given if pregenerate_cutouts"):
            AstrometricCorrections(
                **_kwargs, ax_dimension=1, npy_or_csv='csv', pregenerate_cutouts=False,
                coord_or_chunk='coord', coord_system='equatorial')
        ac = AstrometricCorrections(
            **_kwargs, ax_dimension=1, npy_or_csv='csv', pregenerate_cutouts=False,
            coord_or_chunk='coord', coord_system='equatorial', cutout_area=60, cutout_height=6)
        self.a_cat_name = 'store_data/a_cat{}{}.npy'
        self.b_cat_name = 'store_data/b_cat{}{}.npy'
        with pytest.raises(ValueError, match='a_cat_func must be given if pregenerate_cutouts '):
            ac(self.a_cat_name, self.b_cat_name, a_cat_func=None, b_cat_func=None,
               cat_recreate=True, snr_model_recreate=True, count_recreate=True, tri_download=False,
               dens_recreate=True, nn_recreate=True, auf_sim_recreate=True, auf_pdf_recreate=True,
               h_o_fit_recreate=True, fit_x2s_recreate=True, make_plots=True,
               make_summary_plot=True)
        with pytest.raises(ValueError, match='b_cat_func must be given if pregenerate_cutouts '):
            ac(self.a_cat_name, self.b_cat_name, a_cat_func=self.fake_cata_cutout, b_cat_func=None,
               cat_recreate=True, snr_model_recreate=True, count_recreate=True, tri_download=False,
               dens_recreate=True, nn_recreate=True, auf_sim_recreate=True, auf_pdf_recreate=True,
               h_o_fit_recreate=True, fit_x2s_recreate=True, make_plots=True,
               make_summary_plot=True)
        dd_params = np.load(os.path.join(os.path.dirname(__file__), 'data/dd_params.npy'))
        l_cut = np.load(os.path.join(os.path.dirname(__file__), 'data/l_cut.npy'))
        ax1_mids, ax2_mids = np.array([105], dtype=float), np.array([0], dtype=float)
        magarray = np.array([14.07, 14.17, 14.27, 14.37])
        magslice = np.array([0.05, 0.05, 0.05, 0.05])
        sigslice = np.array([0.1, 0.1, 0.1, 0.1])
        chunks = None
        ax_dimension = 1
        ac = AstrometricCorrections(
            psf_fwhm=6.1, numtrials=1000, nn_radius=30, dens_search_radius=900,
            save_folder='ac_save_folder', trifolder='tri_folder', triname='trilegal_sim',
            maglim_b=13, maglim_f=25, magnum=11, trifilterset='2mass_spitzer_wise',
            trifiltname='W1', gal_wav_micron=3.35, gal_ab_offset=2.699, gal_filtname='wise2010-W1',
            gal_alav=0.039, bright_mag=16, dm=0.1, dd_params=dd_params, l_cut=l_cut,
            ax1_mids=ax1_mids, ax2_mids=ax2_mids, ax_dimension=ax_dimension, cutout_area=60,
            cutout_height=6, mag_array=magarray, mag_slice=magslice, sig_slice=sigslice, n_pool=1,
            npy_or_csv='npy', coord_or_chunk='coord',
            pos_and_err_indices=[[0, 1, 2], [0, 1, 2]], mag_indices=[3], mag_unc_indices=[4],
            mag_names=['W1'], best_mag_index=0, coord_system='equatorial', chunks=chunks,
            pregenerate_cutouts=True)
        self.npy_or_csv = 'npy'
        cat_args = (105.0, 0.0)
        if os.path.isfile(self.a_cat_name.format(*cat_args)):
            os.remove(self.a_cat_name.format(*cat_args))
        if os.path.isfile(self.b_cat_name.format(*cat_args)):
            os.remove(self.b_cat_name.format(*cat_args))
        a_cat_func = None
        b_cat_func = None
        with pytest.raises(ValueError, match="If pregenerate_cutouts is 'True' all files must "
                           "exist already, but {} does not.".format(
                               self.a_cat_name.format(*cat_args))):
            ac(self.a_cat_name, self.b_cat_name, a_cat_func, b_cat_func, cat_recreate=True,
               snr_model_recreate=True, count_recreate=True, tri_download=False, dens_recreate=True,
               nn_recreate=True, auf_sim_recreate=True, auf_pdf_recreate=True,
               h_o_fit_recreate=True, fit_x2s_recreate=True, make_plots=True,
               make_summary_plot=True)
        ax1_min, ax1_max, ax2_min, ax2_max = 100, 110, -3, 3
        self.fake_cata_cutout(ax1_min, ax1_max, ax2_min, ax2_max, *cat_args)
        with pytest.raises(ValueError, match="If pregenerate_cutouts is 'True' all files must "
                           "exist already, but {} does not.".format(
                               self.b_cat_name.format(*cat_args))):
            ac(self.a_cat_name, self.b_cat_name, a_cat_func, b_cat_func, cat_recreate=True,
               snr_model_recreate=True, count_recreate=True, tri_download=False, dens_recreate=True,
               nn_recreate=True, auf_sim_recreate=True, auf_pdf_recreate=True,
               h_o_fit_recreate=True, fit_x2s_recreate=True, make_plots=True,
               make_summary_plot=True)

    @pytest.mark.parametrize("npy_or_csv,coord_or_chunk,coord_system,pregenerate_cutouts",
                             [("csv", "chunk", "equatorial", True),
                              ("npy", "coord", "galactic", False)])
    def test_fit_astrometry(self, npy_or_csv, coord_or_chunk, coord_system, pregenerate_cutouts):
        self.npy_or_csv = npy_or_csv
        dd_params = np.load(os.path.join(os.path.dirname(__file__), 'data/dd_params.npy'))
        l_cut = np.load(os.path.join(os.path.dirname(__file__), 'data/l_cut.npy'))
        ax1_mids, ax2_mids = np.array([105], dtype=float), np.array([0], dtype=float)
        magarray = np.array([14.07, 14.17, 14.27, 14.37])
        magslice = np.array([0.05, 0.05, 0.05, 0.05])
        sigslice = np.array([0.1, 0.1, 0.1, 0.1])
        if coord_or_chunk == 'coord':
            chunks = None
            ax_dimension = 1
        else:
            chunks = [2017]
            ax_dimension = 2
        ac = AstrometricCorrections(
            psf_fwhm=6.1, numtrials=1000, nn_radius=30, dens_search_radius=900,
            save_folder='ac_save_folder', trifolder='tri_folder', triname='trilegal_sim',
            maglim_b=13, maglim_f=25, magnum=11, trifilterset='2mass_spitzer_wise',
            trifiltname='W1', gal_wav_micron=3.35, gal_ab_offset=2.699, gal_filtname='wise2010-W1',
            gal_alav=0.039, bright_mag=16, dm=0.1, dd_params=dd_params, l_cut=l_cut,
            ax1_mids=ax1_mids, ax2_mids=ax2_mids, ax_dimension=ax_dimension, mag_array=magarray,
            mag_slice=magslice, sig_slice=sigslice, n_pool=1, npy_or_csv=npy_or_csv,
            coord_or_chunk=coord_or_chunk, pos_and_err_indices=[[0, 1, 2], [0, 1, 2]],
            mag_indices=[3], mag_unc_indices=[4], mag_names=['W1'], best_mag_index=0,
            coord_system=coord_system, chunks=chunks, pregenerate_cutouts=pregenerate_cutouts,
            cutout_area=60 if not pregenerate_cutouts else None,
            cutout_height=6 if not pregenerate_cutouts else None)

        if coord_or_chunk == 'coord':
            self.a_cat_name = 'store_data/a_cat{}{}.npy'
            self.b_cat_name = 'store_data/b_cat{}{}.npy'
        else:
            self.a_cat_name = 'store_data/a_cat{}.npy'
            self.b_cat_name = 'store_data/b_cat{}.npy'
        if pregenerate_cutouts:
            # Cutout area is 60 sq deg with a height of 6 deg for a 10x6 box around (105, 0).
            cat_args = (chunks[0],)
            ax1_min, ax1_max, ax2_min, ax2_max = 100, 110, -3, 3
            self.fake_cata_cutout(ax1_min, ax1_max, ax2_min, ax2_max, *cat_args)
            self.fake_catb_cutout(ax1_min, ax1_max, ax2_min, ax2_max, *cat_args)
            a_cat_func = None
            b_cat_func = None
        else:
            a_cat_func = self.fake_cata_cutout
            b_cat_func = self.fake_catb_cutout
        ac(self.a_cat_name, self.b_cat_name, a_cat_func, b_cat_func, cat_recreate=True,
           snr_model_recreate=True, count_recreate=True, tri_download=False, dens_recreate=True,
           nn_recreate=True, auf_sim_recreate=True, auf_pdf_recreate=True,
           h_o_fit_recreate=True, fit_x2s_recreate=True, make_plots=True, make_summary_plot=True)

        if coord_or_chunk == 'coord':
            assert os.path.isfile('ac_save_folder/pdf/auf_fits_105.0_0.0.pdf')
        else:
            assert os.path.isfile('ac_save_folder/pdf/auf_fits_2017.pdf')
        assert os.path.isfile('ac_save_folder/pdf/counts_comparison.pdf')
        assert os.path.isfile('ac_save_folder/pdf/s_vs_snr_W1.pdf')
        assert os.path.isfile('ac_save_folder/pdf/sig_fit_comparisons.pdf')
        assert os.path.isfile('ac_save_folder/pdf/sig_h_stats.pdf')

        marray = np.load('ac_save_folder/npy/m_sigs_array.npy')
        narray = np.load('ac_save_folder/npy/n_sigs_array.npy')
        assert_allclose([marray[0], narray[0]], [2, 0], rtol=0.1, atol=0.01)

        lmids = np.load('ac_save_folder/npy/ax1_mids.npy')
        bmids = np.load('ac_save_folder/npy/ax2_mids.npy')
        assert_allclose([lmids[0], bmids[0]], [105, 0], atol=0.001)

        abc_array = np.load('ac_save_folder/npy/snr_mag_params.npy')
        assert_allclose(abc_array[0, 0, 0], 1.2e-2, rtol=0.05, atol=0.001)
        assert_allclose(abc_array[0, 0, 1], 8e-17, rtol=0.05, atol=5e-19)

        assert_allclose(ac.ax1_mins[0], 100, rtol=0.01)
        assert_allclose(ac.ax1_maxs[0], 110, rtol=0.01)
        assert_allclose(ac.ax2_mins[0], -3, rtol=0.01)
        assert_allclose(ac.ax2_maxs[0], 3, rtol=0.01)
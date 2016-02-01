% Code to solve the elastic sea level equation following 
% Kendall et al., 2005 and Austermann et al., 2015

% J. Austermann 2015

% add paths when run for the first time.
% addpath SLFunctions
% addpath SLFunctions/upslope
% addpath '/Users/jackyaustermann/Documents/MATLAB/m_map'

%% Parameters & Input 
% Specify maximum degree to which spherical transformations should be done
maxdeg = 256;

% parameters
rho_ice = 916;
rho_water = 1000;
rho_sed = 2300;
g = 9.81;


% The following steps help speed up the calculations
% Set up Gauss Legendre grid onto which to interpolate all grids
N = maxdeg; 
[x,w] = GaussQuad(N);
x_GL = acos(x)*180/pi - 90;
lon_GL = linspace(0,360,2*N+1);
lon_GL = lon_GL(1:end-1);

colat = 90 - x_GL;
lon = lon_GL;

[lon_out,lat_out] = meshgrid(lon_GL,x_GL);

% Precompute legendre polynomials
[P_lm_spa2sph, P_lm_sph2spa] = get_Legendre(x_GL,maxdeg);


% --------------------------------
% ICE
% --------------------------------

% load WAIS 
load ice5g_griddata

ind_0 = find(ice_time == 12);
ind_j = find(ice_time == 11.5);

% already on Gauss Legendre grid
ice_0_nointerp = squeeze(ice5g_grid(ind_0,:,:));
ice_j_nointerp = squeeze(ice5g_grid(ind_j,:,:));

% interpolate ice masks on common grid
ice_0 = interp2(ice_long,ice_lat,ice_0_nointerp,lon_out, lat_out);
ice_j = interp2(ice_long,ice_lat,ice_j_nointerp,lon_out, lat_out);

% patch in zeros
ice_0(isnan(ice_0) == 1) = 0;
ice_j(isnan(ice_j) == 1) = 0;

del_ice = ice_j - ice_0; 


% --------------------------------
% DYNAMIC TOPOGRAPHY
% --------------------------------

del_DT = zeros(size(del_ice));


% --------------------------------
% SEDIMENT
% --------------------------------

del_sed = zeros(size(del_ice));


% --------------------------------
% TOPOGRAPHY
% --------------------------------

% load preloaded etopo (including ice) as topo_orig, lon_topo, lat_topo
load topo_SL

% interpolate topography grid onto Gauss Legendre Grid
topo0 = interp2(lon_topo,lat_topo,topo_orig,lon_out, lat_out);



%% Set up love number input

% prepare love numbers in suitable format and calculate T_lm and E_lm 
% to calculate the fluid case, switch h_el to h_fl, k_el to k_fl and same
% for tidal love numbers
load SavedLN/LN_l90_VM2
h_lm = love_lm(h_el, maxdeg);
k_lm = love_lm(k_el, maxdeg);
h_lm_tide = love_lm(h_el_tide,maxdeg);
k_lm_tide = love_lm(k_el_tide,maxdeg);

E_lm = 1 + k_lm - h_lm;
T_lm = get_tlm(maxdeg);

E_lm_T = 1 + k_lm_tide - h_lm_tide;

% can switch this in if you want to exclude rotational effects
% E_lm_T = zeros(size(E_lm_T));

%% Solve sea level equation (after Kendall 2005, Dalca 2013 & Austermann et al. 2015)

k_max = 10;   % maximum number of iterations
epsilon = 10^-4; % convergence criterion

% 0 = before
% j = after

% set up present-day topo and ocean function 
topo_0 = topo0 + ice_0; % already includes ice and dynamic topography
oc_0 = sign_01(topo_0);

% set up topography and ocean function after the ice change
topo_j = topo_0 + ice_j; % del_ice is negative -> subtract ice that is melted
oc_j = sign_01(topo_j);

% calculate change in sediments and decompose into spherical harmonics
Sed_lm = spa2sph(del_sed,maxdeg,lon,colat,P_lm_spa2sph);

% expand ocean function into spherical harmonics
oc0_lm = spa2sph(oc_0,maxdeg,lon,colat,P_lm_spa2sph);

% no proglacial lakes in step 0 
P_0 = zeros(size(oc_j));


% initial values for convergence
conv = 'not converged yet';

        
for k = 1:k_max % loop for sea level and topography iteration

    switch conv

        case 'converged!'

        case 'not converged yet'
            
        % expand ocean function into spherical harmonics
        ocj_lm = spa2sph(oc_j,maxdeg,lon,colat,P_lm_spa2sph);

        % CHECK ICE MODEL 
        % check ice model for floating ice
        check1 = sign_01(-topo_j + ice_j);
        check2 = sign_01(+topo_j - ice_j) .* ...
         (sign_01(-ice_j*rho_ice - (topo_j - ice_j)*rho_water));
        
        ice_j_corr = check1.*ice_j + check2.*ice_j;
        del_ice_corrected = ice_j_corr - ice_0; 
        
        deli_lm = spa2sph(del_ice_corrected,maxdeg,lon,colat,P_lm_spa2sph);
        
        % determine the depression adjacent to ice sheets;
        P_j = calc_lake(ice_j_corr,oc_j,topo_j,lat_out,lon_out);
        delP = P_j - P_0;
        delP_lm = spa2sph(delP,maxdeg,lon,colat,P_lm_spa2sph);
        
        % calculate topography correction
        TO = topo_0.*(oc_j-oc_0);
        % expand TO function into spherical harmonics
        TO_lm = spa2sph(TO,maxdeg,lon,colat,P_lm_spa2sph);
        
        
        % set up initial guess for sea level change
        if k == 1
            % initial guess of sea level change is just to distribute the
            % ice over the oceans
            delS_lm = ocj_lm/ocj_lm(1)*(-rho_ice/rho_water*deli_lm(1) + ...
                TO_lm(1) - delP_lm(1));
            % convert into spherical harmonics
            delS_init = sph2spa(delS_lm,maxdeg,lon,colat,P_lm_sph2spa);
            
        end
        
        % calculate loading term
        L_lm = rho_ice*deli_lm + rho_water*delS_lm + rho_sed*Sed_lm + ...
            rho_water*delP_lm;

        % calculate contribution from rotation
        La_lm = calc_rot(L_lm,k_el,k_el_tide);

        % calculate sea level perturbation
        % add ice and sea level and multiply with love numbers
        % DT doesn't load!
        delSLcurl_lm_fl = E_lm .* T_lm .* L_lm + ...
            1/g*E_lm_T.*La_lm;

        % convert to spherical harmonics and subtract terms that are part
        % of the topography to get the 'pure' sea level change
        delSLcurl_fl = sph2spa(delSLcurl_lm_fl,maxdeg,lon,colat,P_lm_sph2spa);
        delSLcurl = delSLcurl_fl - del_ice_corrected - del_DT - del_sed;


        % compute and decompose RO
        RO = delSLcurl.*oc_j;
        RO_lm = spa2sph(RO,maxdeg,lon,colat,P_lm_spa2sph);

        % calculate eustatic sea level perturbation (delta Phi / g)
        delPhi_g = 1/ocj_lm(1) * (- rho_ice/rho_water*deli_lm(1) ...
            - RO_lm(1) + TO_lm(1) - delP_lm(1));

        % calculate overall perturbation of sea level over oceans
        % (spatially varying field and constant offset)
        delSL = delSLcurl + delPhi_g;


        % update topography and ocean function
        topo_j = - delSL + topo_0;
        oc_j = sign_01(topo_j);


        % calculate change in ocean height and decompose
        delS_new = delSL.*oc_j -  topo_0.*(oc_j-oc_0);
        delS_lm_new = spa2sph(delS_new,maxdeg,lon,colat,P_lm_spa2sph);


        % calculate convergence criterion chi
        chi = abs( (sum(abs(delS_lm_new)) - sum(abs(delS_lm))) / ...
            sum(abs(delS_lm)) );

        % check convergence against the value epsilon
        % If converged, set the variable conv to 'converged!' so that the
        % calculation exits the loop. If not converged iterate again.
        if chi < epsilon;
            conv = 'converged!';
            disp(['Converged after iteration ' num2str(k) '. Chi was ' num2str(chi) '.'])
        else
            conv = 'not converged yet';
            disp(['Finished iteration ' num2str(k) '. Chi was ' num2str(chi) '.'])
        end

        % update sea sea surface height
        delS_lm = delS_lm_new;
    end

end



%% Plot results

% We only want the sea level change cause by melted ice, so subtract
% del_ice
SL_change = delSL + del_ice_corrected;
plotSL = SL_change - SL_save;

% plot
figure
m_proj('robinson','clongitude',0);
m_pcolor([lon_out(:,end/2+1:end)-360 lon_out(:,1:end/2)],lat_out,...
    [plotSL(:,end/2+1:end) plotSL(:,1:end/2)])
m_coast('color',[0 0 0]);
m_grid('box','fancy','xticklabels',[],'yticklabels',[]);
shading flat
colorbar
colormap(jet)

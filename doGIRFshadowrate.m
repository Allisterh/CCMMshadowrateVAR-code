%#ok<*NOSEL>
%#ok<*DISPLAYPROG>
%#ok<*UNRCH>
%#ok<*ASGLU>
%#ok<*DATNM>
%#ok<*DATST>

%% load em toolboxes
warning('off','MATLAB:handle_graphics:exceptions:SceneNode')

path(pathdef)

addpath matlabtoolbox/emtools/
addpath matlabtoolbox/emtexbox/
addpath matlabtoolbox/emgibbsbox/
addpath matlabtoolbox/emeconometrics/
addpath matlabtoolbox/emstatespace/

rng(01012023)

%% Initial operations
clear; close all; clc;


%% set parameters for VAR and MCMC
datalabel           = 'fredMD20VXO-2022-09';
jumpDate            = datenum(2022,08,01);
check_stationarity  = 0;                  % Truncate nonstationary draws? (1=yes)

doIRF               = true;
irfSCALES           = [1 10];
irfDATES            = [datenum(2007,1,1) datenum(2009,1,1) datenum([2010 2012 2014],12,1)];

p                   = 12;                    % Number of lags on dependent variables
MCMCdraws           = 1e3;                   % Final number of MCMC draws after burn in
irfNdraws           = 1e3;                   % per MCMC node
ELBbound            = 0.25;

% SED-PARAMETERS-HERE
MCMCdraws           = 1e2;                   % Final number of MCMC draws after burn in
irfNdraws           = 1e2;                   % per MCMC node
irfSCALES           = 1;
p                   = 3;

%% process ELB setting
switch ELBbound
    case .25
        ELBtag    = '';
    case .125
        ELBtag    = '-ELB125';
    case .5
        ELBtag    = '-ELB500';
    otherwise
        error('ELBbound value of %5.2f not recognized', ELBbound)
end

irfHorizon          = 25;
fcstNhorizons       = irfHorizon;                 % irrelevant here
fcstNdraws          = MCMCdraws;             % irrelevant here


doRATSprior         = true;

samStart            = [];                 % truncate start of sample if desired (leave empty if otherwise)

doELBsampling       = true;
doPAIactual         = false;

np = 12;

Nworker     = getparpoolsize;
if Nworker == 0
    Nworker = 1;
end
rndStreams  = initRandStreams(Nworker);


%% load data
% load CSV file
dum=importdata(sprintf('%s.csv', datalabel),',');


ydates=dum.data(3:end,1);
% Variable names
ncode=dum.textdata(1,2:end);
% Transformation codes (data are already transformed)
tcode  =dum.data(1,2:end);
cumcode=logical(dum.data(2,2:end));
cumcode(tcode == 5) = 1;
% Data
data=dum.data(3:end,2:end);

setShadowYields

ndxYIELDS = union(ndxSHADOWRATE, ndxOTHERYIELDS);
Nyields   = length(ndxYIELDS);

Nshadowrates = length(ndxSHADOWRATE);
Tdata = length(ydates);

Ylabels = fredMDprettylabel(ncode);

%% process settings
N     = size(data,2);
K     = N * p + 1; % number of regressors per equation


% truncate start of sample (if desired)
if ~isempty(samStart)
    ndx    = ydates >= samStart;
    data   = data(ndx,:);
    ydates = ydates(ndx);
    Tdata  = length(ydates);
end

% define oos jump offs

ELBdummy = data(:,ndxSHADOWRATE) <= ELBbound;

startELB       = find(any(ELBdummy,2), 1);
elbT0          = startELB - 1 - p;
% elbT0: first obs prior to missing obs, this is the jump off for the state space
% note: startELB is counted against the available obs in sample, which include
% p additional obs compared to the VAR



%% some parameters
setMinnesotaMean

fontsize = 12;

TID   = parid;

thisT = find(ydates == jumpDate);
T     = thisT - p;

setQuantiles    = [.5, 2.5, 5, normcdf(-1) * 100, 25 , 75,  (1 - normcdf(-1)) * 100, 95, 97.5, 99.5];
Nquantiles      = length(setQuantiles);
ndxCI68         = ismember(setQuantiles, [normcdf(-1) * 100, 100 - normcdf(-1) * 100]);
ndxCI90         = ismember(setQuantiles, [5 95]);
ndxCI           = ndxCI68 | ndxCI90;

%% MCMC sampler

rndStream   = getDefaultStream;

[PAI_all, PHI_all, invA_all, sqrtht_all, shadowrate_all, ...
    ] = mcmcVARshadowrate(thisT, MCMCdraws,...
    p, np, data, ydates, ...
    minnesotaPriorMean, doRATSprior, doPAIactual, ...
    ndxSHADOWRATE, ndxOTHERYIELDS, doELBsampling, ELBbound, elbT0, check_stationarity, ...
    [], [], ...
    [], ... % yrealized
    fcstNdraws, fcstNhorizons, rndStream, true);

%% store MCMC
titlename=sprintf('%s%s-p%d-jumpoff%s', datalabel, ELBtag, p, datestr(jumpDate, 'yyyymmm'));

allw = whos;
ndx = contains({allw.class}, 'Figure');
if any(ndx)
    clear(allw(ndx).name)
end
save(sprintf('mcmcShadowrate-%s.mat', titlename), '-v7.3')


%% collect MCMC draws
PAIdraws  = permute(PAI_all, [3 2 1]);
invAdraws = permute(invA_all, [2 3 1]);
PHIdraws  = permute(PHI_all, [2 1]);
[~, ndxvech]    = ivech(PHIdraws(:,1));
SVdraws   = sqrtht_all;
shadowrateDraws = shadowrate_all;

clear PAI_all invA_all PHI_all sqrtht_all shadowrate_all

%% GIRF
if doIRF
    for IRF1scale = irfSCALES

        display(IRF1scale)

        for irfDate = irfDATES

            display(datestr(irfDate, 'yyyymmm'))


            % prepare wrap
            titlename=sprintf('shadowrate-%s-p%d-IRF1scale%d-jumpoff%s-irfDate%s', datalabel, p, IRF1scale, ...
                datestr(jumpDate, 'yyyymmm'), datestr(irfDate, 'yyyymmm'));

            if ~isempty(samStart)
                titlename = strcat(titlename,'-', datestr(samStart, 'yyyymmm'));
            end

            wrap = [];
            initwrap

            ndxIRFT0               = find(ydates == irfDate);
            shadowrateJumpoffDraws = permute(shadowrateDraws(:,:,1:ndxIRFT0 - elbT0 - p), [3 2 1]);
            SVjumpoffDraws         = permute(SVdraws(:,ndxIRFT0 - p,:), [3 1 2]);
            % allocate memory
            [fcstYdraws, fcstYdraws1plus, fcstYdraws1minus] = deal(NaN(N, irfHorizon, irfNdraws, MCMCdraws));

            % prepare state space for forecast simulation

            ndxfcstY          = 1+(1:N);
            fcstB             = zeros(K,N);
            fcstB(ndxfcstY,:) = eye(N);

            % construct forecast jumpoff (with placeholders for shadow rates)
            jumpoffDate       = ydates(thisT);
            ndx               = ydates <= jumpoffDate;
            jumpoffData       = data(ndx,:);

            prc70 = normcdf([-1 1]) * 100;

            %% loop over MCMC draws
            parfor mm = 1 : MCMCdraws

                TID       = parid;
                rndStream = rndStreams{TID};

                % parfor preps (better to do inside parfor loop)
                thisData               = jumpoffData;
                fcstA                  = zeros(K,K);
                fcstA(1,1)             = 1; % unit root for the constant
                fcstA(1+N+1:end,2:end) = [eye(N*(p-1)),zeros(N*(p-1),N)]; % fill in lower part of companion form

                % construct jump off vector
                thisData(p+elbT0+1:ndxIRFT0,ndxSHADOWRATE) = shadowrateJumpoffDraws(:,:,mm);
                Xjumpoff    = zeros(K,1);
                Xjumpoff(1) = 1;
                for l=1:p
                    Xjumpoff(1+(l-1)*N+(1:N)) = thisData(ndxIRFT0-(l-1),1:N);
                end
                fcstX0                        = Xjumpoff;

                % map into state space
                fcstA(ndxfcstY, :)  = PAIdraws(:,:,mm);

                PHI     = ivech(PHIdraws(:,mm), ndxvech);

                % generate SV paths
                sqrtPHI     = chol(PHI, 'lower');
                logSV       = sqrtPHI * randn(rndStream, N, irfHorizon * irfNdraws);
                logSV       = reshape(logSV, N, irfHorizon, irfNdraws);
                logSV       = cumsum(logSV,2);
                fcstSVdraws = exp(logSV * 0.5) .* SVjumpoffDraws(:,mm);
                nushocks    = fcstSVdraws .* randn(rndStream, N, irfHorizon, irfNdraws);

                % baseline
                fcstYdraws(:,:,:,mm)       = simVARshadowrate(N, fcstX0, ndxfcstY, cumcode, np, fcstA, fcstB, invAdraws(:,:,mm), ...
    				nushocks, ELBbound, ndxYIELDS, irfHorizon, irfNdraws);
                % positive shock
                nushocks(1,1,:)            = IRF1scale;
                fcstYdraws1plus(:,:,:,mm)  = simVARshadowrate(N, fcstX0, ndxfcstY, cumcode, np, fcstA, fcstB, invAdraws(:,:,mm), ...
    				nushocks, ELBbound, ndxYIELDS, irfHorizon, irfNdraws);
                % negative shock
                nushocks(1,1,:)            = -1 * IRF1scale;
                fcstYdraws1minus(:,:,:,mm) = simVARshadowrate(N, fcstX0, ndxfcstY, cumcode, np, fcstA, fcstB, invAdraws(:,:,mm), ...
    				nushocks, ELBbound, ndxYIELDS, irfHorizon, irfNdraws);

            end % parfor

            clear logSV fcstSVdraws nushocks

            %% forecast moments
            fcstYhat       = mean(fcstYdraws, [3 4]);
            fcstYhat1plus  = mean(fcstYdraws1plus, [3 4]);
            fcstYhat1minus = mean(fcstYdraws1minus, [3 4]);

            YhatBaseline   = mean(fcstYdraws, 3);
            clear fcstYdraws

            %% IRF
            IRFdraws1plus   = mean(fcstYdraws1plus, 3)  - YhatBaseline;
            clear fcstYdraws1plus
            IRFdraws1minus  = mean(fcstYdraws1minus, 3) - YhatBaseline;
            clear fcstYdraws1minus
            clear YhatBaseline



            IRF1plus        = mean(IRFdraws1plus, 4);
            IRF1plusTails   = prctile(IRFdraws1plus, prc70, 4);

            IRF1minus       = mean(IRFdraws1minus, 4);
            IRF1minusTails  = prctile(IRFdraws1minus, prc70, 4);

            deltaIRFdraws   = IRFdraws1plus + IRFdraws1minus;
            deltaIRF        = median(deltaIRFdraws,4);
            deltaIRFtails   = prctile(deltaIRFdraws, prc70, 4);

            clear deltaIRFdraws IRFdraws1plus IRFdraws1minus

            %% PLOT RESULTS
            colorPlus     = Colors4Plots(1);
            colorMinus    = Colors4Plots(2);
            colorBase     = Colors4Plots(8);

            %% plot ELB IRF
            for n = 1 : N

                thisfig = figure;
                subplot(2,1,1)
                hold on
                set(gca, 'FontSize', fontsize)
                hplus  = plot(0:irfHorizon-1, IRF1plus(n,:), '-', 'color', colorPlus, 'linewidth', 3);
                plot(0:irfHorizon-1, squeeze(IRF1plusTails(n,:,:,:)), '-', 'color', colorPlus, 'linewidth', 1);
                hminus = plot(0:irfHorizon-1, -1 * IRF1minus(n,:), '-.', 'color', colorMinus, 'linewidth', 3);
                plot(0:irfHorizon-1, -1 * squeeze(IRF1minusTails(n,:,:,:)), '-.', 'color', colorMinus, 'linewidth', 1);
                xlim([0 irfHorizon-1])
                yline(0, 'k:')
                legend([hplus, hminus], 'response', 'inverted response to negative shock', 'location', 'southoutside')
                title('positive shock', 'FontWeight', 'normal')

                subplot(2,1,2)
                hold on
                set(gca, 'FontSize', fontsize)
                hminus = plot(0:irfHorizon-1, IRF1minus(n,:), '-', 'color', colorMinus, 'linewidth', 3);
                plot(0:irfHorizon-1, squeeze(IRF1minusTails(n,:,:,:)), '-', 'color', colorMinus, 'linewidth', 1);
                hplus  = plot(0:irfHorizon-1, -1 * IRF1plus(n,:), '-.', 'color', colorPlus, 'linewidth', 3);
                plot(0:irfHorizon-1, -1 * squeeze(IRF1plusTails(n,:,:,:)), '-.', 'color', colorPlus, 'linewidth', 1);
                xlim([0 irfHorizon-1])
                yline(0, 'k:')
                legend([hminus, hplus], 'response', 'inverted response to positive shock', 'location', 'southoutside')
                title('negative shock', 'FontWeight', 'normal')

                sgtitle(sprintf('%s per %s', Ylabels{n}, datestr(irfDate, 'yyyymmm')), 'FontSize', 18', 'FontWeight', 'bold')

                wrapthisfigure(thisfig, sprintf('IRF1plusminus-%s-IRF1scale%d-%s-jumpoff%s-irfDate%s', datalabel, IRF1scale, ncode{n}, ...
                    datestr(jumpDate, 'yyyymmm'), datestr(irfDate, 'yyyymmm')), wrap)
            end


            %% plot delta ELB IRF
            for n = 1 : N

                thisfig = figure;
                hold on
                set(gca, 'FontSize', fontsize)

                plot(0:irfHorizon-1, deltaIRF(n,:), '-', 'color', colorPlus, 'linewidth', 2);
                plot(0:irfHorizon-1, squeeze(deltaIRFtails(n,:,:,:)), '-', 'color', colorPlus, 'linewidth', 1);

                xlim([0 irfHorizon-1])
                yline(0, 'k:')

                title(sprintf('%s', Ylabels{n}))

                wrapthisfigure(thisfig, sprintf('deltaIRFplusminus-%s-IRF1scale%d-%s-jumpoff%s-irfDate%s', datalabel, IRF1scale, ncode{n}, ...
                    datestr(jumpDate, 'yyyymmm'), datestr(irfDate, 'yyyymmm')), wrap)

            end


            %% Response paths
            for n = 1 : N

                thisfig = figure;
                hold on
                set(gca, 'FontSize', fontsize)

                hbase  = plot(0:irfHorizon-1, fcstYhat(n,:), '-', 'color', colorBase, 'linewidth', 2);
                hplus  = plot(0:irfHorizon-1, fcstYhat1plus(n,:), '-', 'color', colorPlus, 'linewidth', 2);
                hminus = plot(0:irfHorizon-1, fcstYhat1minus(n,:), '-', 'color', colorMinus, 'linewidth', 2);

                xlim([0 irfHorizon-1])

                if any(ndxYIELDS == n) && ~(all(ylim > ELBbound) || all(ylim < ELBbound))
                    hELB = yline(ELBbound, ':', 'color', Colors4Plots(5), 'LineWidth',2);
                    legend([hbase hplus hminus hELB], 'baseline', 'positive shock', 'negative shock', 'ELB', ...
                        'location', 'best')
                else
                    legend([hbase hplus hminus], 'baseline', 'positive shock', 'negative shock', 'location', 'best')
                end
                title(sprintf('%s per %s', Ylabels{n}, datestr(irfDate, 'yyyymmm')), 'FontWeight', 'normal')
                wrapthisfigure(thisfig, sprintf('pathResponses1plusminus-%s-IRF1scale%d-%s-jumpoff%s-irfDate%s', datalabel, IRF1scale, ncode{n}, ...
                    datestr(jumpDate, 'yyyymmm'), datestr(irfDate, 'yyyymmm')), wrap)
            end

            %% wrap up
            allw = whos;
            ndx = contains({allw.class}, 'Figure');
            if any(ndx)
                clear(allw(ndx).name)
            end
            save(sprintf('irfShadowrate-%s.mat', titlename), '-v7.3')

            close all
            finishwrap

        end % irfDate
    end % irfscale
end % doIRF

finishscript


%% define forecast simulation as function
function ydraws = simVARshadowrate(N, fcstX0, ndxfcstY, cumcode, np, fcstA, fcstB, invA, nushocks, ELBbound, ndxYIELDS, irfHorizon, irfNdraws)

ydraws      = NaN(N,irfHorizon,irfNdraws);
theseShocks = zeros(N, irfHorizon+1); % padded with zeros for use with ltitr

for nn = 1 : irfNdraws
    theseShocks(:,1:irfHorizon)  = invA * nushocks(:,:,nn);
    xdraws         = ltitr(fcstA, fcstB, theseShocks', fcstX0); % faster forecast simulation using ltitr
    ydraws(:,:,nn) = xdraws(2:end,ndxfcstY)';
end

yieldDraws                   = ydraws(ndxYIELDS,:,:);
ndx                          = yieldDraws < ELBbound;
yieldDraws(ndx)              = ELBbound;
ydraws(ndxYIELDS,:,:)        = yieldDraws;

ydraws(cumcode, :,:)         = cumsum(ydraws(cumcode,:,:), 2) / np;

end % function simVARshadowrate

% testing slicewise recon BJ v 
% vs 
% cleaner james v 
% bj tmp file of 10x12 
%% Details on BJ's restarting cs
% /civmnas4/rja20/S66617.work/S66617_m024/work/S66617_m024.tmp
tmp_iter_stream='/civmnas4/rja20/S66617.work/S66617_m024/work/S66617_m024.tmp';
tmp_replicate  =sprintf('%s/S67962.work/compare_m023.tmp',getenv('BIGGUS_DISKUS'));
if ~exist(tmp_replicate,'file')
    system(sprintf('cp -p %s %s &',tmp_iter_stream,tmp_replicate ));
end
% iter stream call used to generate it
% /cm/shared/workstation_code_dev/shared/pipeline_utilities/iter_stream.sh S66617 $volno 10 120 10;
% actual cs_recon call used. NOTE fermi filter off!
% “streaming_CS_recon heike S66617  N56008_01 ser33 xfmWeight=.002 TVWeight=0.0012 target_machine=delos first_volume=${first_volume} last_volume=${last_volume} planned_ok chunk_size=2 Itnlim=${ic} keep_work unrecognized_ok verbosity”
% 
%% Commands run to extract a volume fid from our macaque and get its workspace
%%% this was run in debugging to get volume manager command 
% streaming_CS_recon_main_exec heike S67962 LOCAL FID xfmWeight=.002 TVWeight=0.0012 target_machine=delos first_volume=25 last_volume=25 planned_ok chunk_size=10 iteration_strategy=10x5 unrecognized_ok
% /cm/shared/workstation_code_dev/matlab_execs/volume_manager_executable/macaque_v1/run_volume_manager_exec.sh /cm/shared/apps/MATLAB/R2015b/ /mnt/civmbigdata/civmBigDataVol/jjc29/S67962.work/S67962recon.mat S67962_m024 25 /mnt/civmbigdata/civmBigDataVol/jjc29/S67962.work
%%% this was run in debugging to get the volume extract command
% volume_manager_exec /mnt/civmbigdata/civmBigDataVol/jjc29/S67962.work/S67962recon.mat S67962_m024 25 /mnt/civmbigdata/civmBigDataVol/jjc29/S67962.work
%{
% had to mkdir because it was already removed 
mkdir /mnt/civmbigdata/civmBigDataVol/jjc29/S67962.work/S67962_m024///work/
get_subvolume_from_fid('/mnt/civmbigdata/civmBigDataVol/jjc29/S67962.work/S67962.fid',...
    '/mnt/civmbigdata/civmBigDataVol/jjc29/S67962.work/S67962_m024///work//S67962_m024.fid',...
    25,982056988);
%}
%{ 
% setup work was run in debug mode beacuse the work was done already and we
% had to get a new workspace. This was accomplished by just setting the
% starting point after extracting the fid as above
setup_volume_work_for_CSrecon_exec /mnt/civmbigdata/civmBigDataVol/jjc29/S67962.work/S67962_m024///S67962_m024_setup_variables.mat 25;
%}
%% testing setup vars and paths
% copy code to a file we can run, in this case copied the old version to _BJ, 
% then copied the fnl1verbose function to a _BJ version, and modified
% slicewise to use it.
run compile__pathset
mat_runtime='/cm/shared/apps/MATLAB/R2015b/';
mat_execs='/cm/shared/workstation_code_dev/matlab_execs';
function_versions={'slicewise_CSrecon_exec','slicewise_CSrecon_exec_BJ','latest_BJ_needs','BJs_exec','latest','stable','macaque_v1'};

% a pristine normal workspace which we'll duplicate to do single slice
% testing on.
input_workspace='/mnt/civmbigdata/civmBigDataVol/jjc29/S67962.work/S67962_m024/work/S67962_m024_workspace.mat';

% we'll replicate the testing workspace and tmp file for each test function.
test_workspace=cell(size(function_versions));
for fv=1:numel(function_versions)
    fprintf('prep - %s\n',function_versions{fv});
    test_workspace{fv}=slicewise_setup_test(input_workspace,[ function_versions{fv}]);
end
s_idx='0500';
inits=12; % 
init_interval=10;
%% new code this code internalizes re-initalizations, that is why it doesnt happen in a loop.
fv=1;
fprintf('%s\n',function_versions{fv});
ws=matfile(test_workspace{fv},'Writable',true);
aux_param=ws.aux_param;
aux_param.TVWeight =aux_param.TVWeight(1)*ones(1,inits);
aux_param.xfmWeight=aux_param.xfmWeight(1)*ones(1,inits);
param=ws.param;param.Itnlim=init_interval*inits;
ws.aux_param=aux_param;ws.param=param;clear aux_param param ws;
test_CS_exec({function_versions{fv},test_workspace{fv},s_idx});

%% old code
fv=2;
fprintf('%s\n',function_versions{fv});
% old_code do 10
ws=matfile(test_workspace{fv},'Writable',true);
aux_param=ws.aux_param;
aux_param.TVWeight =aux_param.TVWeight(1);
aux_param.xfmWeight=aux_param.xfmWeight(1);
ws.aux_param=aux_param;clear aux_param ws;
% run code upping iters by ten each time
for iters=init_interval:init_interval:init_interval*inits
    ws=matfile(test_workspace{fv},'Writable',true);param=ws.param;param.Itnlim=iters;ws.param=param;clear param ws;
    test_CS_exec({function_versions{fv},test_workspace{fv},s_idx});
end


%% compiled exec code (latest_BJ_needs, BJ_execs,latest,stable,macaque_v1)
parfor fv=3:numel(function_versions);
    fprintf('%s\n',function_versions{fv});
    ws=matfile(test_workspace{fv},'Writable',true);
    aux_param=ws.aux_param;
    aux_param.TVWeight =aux_param.TVWeight(1);
    aux_param.xfmWeight=aux_param.xfmWeight(1);
    ws.aux_param=aux_param;%clear aux_param ws;
    % run code upping iters by ten each time
    for iters=init_interval:init_interval:init_interval*inits
        ws=matfile(test_workspace{fv},'Writable',true);param=ws.param;param.Itnlim=iters;ws.param=param;%clear param ws;
        system(sprintf('%s/slicewise_CSrecon_executable/%s/run_slicewise_CSrecon_exec.sh %s %s %s ',...
            mat_execs,function_versions{fv},mat_runtime,test_workspace{fv},s_idx));
    end
end
%%
stop;
%% compare moved to its own function...
run slicewise_diff_result_load.m
function starting_point = volume_manager_exec(recon_file,volume_runno, volume_number,base_workdir)
% volume_manager_exec(recon_file,volume_runno, volume_number,base_workdir)
% Manages the  compressed sensing reconstruction of an independent 3D volume
% % Functions similarly to old code CS_recon_cluster_bj_multithread_v2[a]
%
%
% Written by BJ Anderson, CIVM
% 21 September 2017
% revised james j cook 2017-
%
% Copyright Duke University
% Authors: Russell Dibb, James J Cook, Robert J Anderson, Nian Wang, G Allan Johnson


% for all execs run this little bit of code which prints start and stop time using magic.
C___=exec_startup();

recon_mat=matfile(recon_file);
% have to unpack structs from the matlab file 
options=recon_mat.options;
% headfile=recon_mat.headfile;
% unpack workstation_settings too
the_scanner=recon_mat.the_scanner;
remote_workstation=recon_mat.remote_workstation;

log_mode=2;
if options.debug_mode>=10
    log_mode=1;
end
log_file=recon_mat.log_file;
try
    volume_dir=fullfile(base_workdir,volume_runno);
catch merr
    volume_dir=fullfile(recon_mat.study_workdir,volume_runno);
end
if ~exist(volume_dir,'dir')
    % our main exec creates ou directory for us, and we want to keep it
    % that way because our slurm-handling files are in there.
    error('Missing expected working directory: %s',volume_dir);
end

% Recon file should contain
%scale_file
%fid_tag_file
%dim_x,dim_y,dim_z
%scanner
%runno
%scanner_patient
%scanner_acquisition
% processed options
%options:
%target_machine
%fermi_filter (and w1/w2)
%chunk_size
%CS_recon_parameters: TVWeight,xfmWeight,Itnlim,wavelet_dims,wavelet_type
%% Reservation support
active_reservation=get_reservation(options.CS_reservation);
%% queue settings
cs_queue=CS_env_queue();
%% Executables support
% set an env var to get latest dev code, or will defacto run stable.
matlab_path = '/cm/shared/apps/MATLAB/R2015b/';
cs_execs=CS_env_execs();
%%
if ischar(volume_number)
    volume_number=str2double(volume_number);
end
if strcmp('/',volume_dir(end))
    volume_dir=[volume_dir '/'];
end

%% Preflight checks
% Determining where we need to start doing work, setting up folders as
% needed.
% 0 : Source fid not ready, run gatekeeper.
% 1 : Extract fid.
% 2 : Run volume setup.
% 3 : Schedule slice jobs.
% 4 : Run volume cleanup.
% 5 : Send volume to workstation and write recon_completed flag.
% 6 : All work done; do nothing.

% Looks like we have a logic glitch where we dont re-run manager unless
% volume cleanup still has yet to run. SO, lets change that(its at the
% end!).

%{
previous more annoyingly specific ugly funciton
[starting_point, log_msg] = check_status_of_CSrecon(volume_workdir,...
    volume_runno, ...
    recon_mat.scanner_name,...
    recon_mat.runno,...
    recon_mat.scanner_patient,...
    recon_mat.scanner_acquisition,...
    recon_mat.bytes_per_block);
%}
% new funtion
scan_data_setup=recon_mat.scan_data_setup;
[starting_point,log_msg,~,data_mode_check]=volume_status(volume_dir,...
    volume_runno, ...
    the_scanner,...
    volume_number,...
    scan_data_setup.fid, ...
    recon_mat.bytes_per_block);

if isfield(data_mode_check,'data_mode')
    % volume status which we call really early has to do this
    % same check internally. If it does that check it will
    % actually return the value packed into a struct.
    data_mode=data_mode_check.data_mode;
    fid_path=data_mode_check.fid_path;
    clear data_mode_check;
else
    [data_mode,fid_path]=get_data_mode(the_scanner, recon_mat.study_workdir, ...
        scan_data_setup.fid);
end

% we've already collected fid_path REFUSE to update remotes by
% reading back previous and only udpating current.
fid_path_prev=recon_mat.fid_path;
fid_path_prev.current=fid_path.current;
recon_mat.Properties.Writable = true;
recon_mat.fid_path=fid_path;
recon_mat.Properties.Writable = false;
clear fid_path_prev;

if ~islogical(options.CS_preview_data)
    if starting_point>2
        warning('CS_preview_data artificially reducing start point to 2');
        starting_point=2;
    end
end
yet_another_logger(log_msg,log_mode,log_file);
% Initialize a log file if it doesn't exist yet.
volume_log_file =fullfile(volume_dir, [volume_runno '_recon.log']);
if ~exist(volume_log_file,'file')
    [s,sout]=system(['touch ' volume_log_file]); assert(s==0,sout);
end

setup_variables= fullfile(volume_dir,   [ volume_runno '_setup_variables.mat']);
images_dir =     fullfile(volume_dir,   [ volume_runno 'images']);
headfile_path =   fullfile(images_dir,[ volume_runno '.headfile']);

work_subfolder = fullfile(volume_dir, 'work');
temp_file =      fullfile(work_subfolder,[ volume_runno '.tmp']);
volume_fid =     fullfile(work_subfolder,[ volume_runno '.fid']);
volume_workspace = fullfile(work_subfolder, [volume_runno '_workspace.mat']);

flag_hf_fail=         fullfile(images_dir,sprintf('.%s_send_headfile_to_%s_FAILED',        volume_runno,remote_workstation.name));
flag_hf_success=      fullfile(images_dir,sprintf('.%s_send_headfile_to_%s_SUCCESSFUL',    volume_runno,remote_workstation.name));
flag_fail=            fullfile(images_dir,sprintf('.%s_send_images_to_%s_FAILED',          volume_runno,remote_workstation.name));
flag_success=         fullfile(images_dir,sprintf('.%s_send_images_to_%s_SUCCESSFUL',      volume_runno,remote_workstation.name));
flag_at_fail=         fullfile(images_dir,sprintf('.%s_send_archive_tag_to_%s_FAILED',     volume_runno,remote_workstation.name));
flag_at_success=      fullfile(images_dir,sprintf('.%s_send_archive_tag_to_%s_SUCCESSFUL', volume_runno,remote_workstation.name));

original_archive_tag= fullfile(images_dir,sprintf('READY_%s',volume_runno));
local_archive_tag_prefix = [ '_' remote_workstation.name];
local_archive_tag =   sprintf('%s%s',original_archive_tag,local_archive_tag_prefix);

if (starting_point == 0) ||  (  recon_mat.nechoes > 1 && starting_point == 1 && volume_number ~=1  )
    %% starting point 0/1
    % FID not ready yet, schedule gatekeeper for us.
    gk_slurm_options=struct;
    gk_slurm_options.v=''; % verbose
    gk_slurm_options.s=''; % shared; gatekeeper definitely needs to share resources.
    gk_slurm_options.mem=512; % memory requested; gatekeeper only needs a miniscule amount.
    gk_slurm_options.p=cs_queue.gatekeeper;
    %gk_slurm_options.job_name = [volume_runno '_gatekeeper'];
    gk_slurm_options.job_name = [recon_mat.runno '_gatekeeper']; %Trying out singleton behavior
    %gk_slurm_options.reservation = active_reservation;
    % using a blank reservation to force no reservation for this job.
    gk_slurm_options.reservation = '';
    scanner_patient_gatekeeper_batch = fullfile(volume_dir, 'sbatch', [ volume_runno '_gatekeeper.bash']);
    % hint: ~ ==> local_or_streaming_or_static
    % [fid_path.current,~] =find_input_fidCS(recon_mat.scanner_name,recon_mat.runno,recon_mat.scanner_patient,recon_mat.scanner_acquisition);
    gatekeeper_args= sprintf('%s %s %s %s %i %i', ...
        volume_fid, fid_path.current, recon_mat.scanner_name, log_file, volume_number, recon_mat.bytes_per_block);
    gatekeeper_cmd = sprintf('%s %s %s ', cs_execs.gatekeeper, matlab_path,...
        gatekeeper_args);
    if ~options.live_run
        batch_file = create_slurm_batch_files(scanner_patient_gatekeeper_batch,gatekeeper_cmd,gk_slurm_options);
        running_jobs = dispatch_slurm_jobs(batch_file,'','','singleton');
    else
        running_jobs='';
        eval(sprintf('gatekeeper_exec %s',gatekeeper_args));
    end
    vm_slurm_options=struct;
    vm_slurm_options.v=''; % verbose
    vm_slurm_options.s=''; % shared; volume manager needs to share resources.
    vm_slurm_options.mem=512; % memory requested; vm only needs a miniscule amount.
    vm_slurm_options.p=cs_queue.full_volume; % For now, will use gatekeeper queue for volume manager as well
    vm_slurm_options.job_name = [volume_runno '_volume_manager'];
    %vm_slurm_options.reservation = active_reservation;
    % using a blank reservation to force no reservation for this job.
    vm_slurm_options.reservation = '';
    volume_manager_batch = fullfile(volume_dir, 'sbatch', [ volume_runno '_volume_manager.bash']);
    vm_args=sprintf('%s %s %i %s',recon_file,volume_runno, volume_number,recon_mat.study_workdir);
    vm_cmd = sprintf('%s %s %s', cs_execs.volume_manager,matlab_path,vm_args);
    if ~options.live_run
        batch_file = create_slurm_batch_files(volume_manager_batch, ...
            vm_cmd,vm_slurm_options);
        or_dependency = '';
        if ~isempty(running_jobs)
            or_dependency='afterok-or';
        end
        c_running_jobs = dispatch_slurm_jobs(batch_file,'',...
            running_jobs,or_dependency);
    else
        eval(sprintf('volume_manager_exec %s',vm_args));
    end
    log_mode = 1;
    log_msg =sprintf('Fid data for volume %s not available yet; initializing gatekeeper (SLURM jobid(s): %s).\n',volume_runno,running_jobs);
    yet_another_logger(log_msg,log_mode,log_file);
    if ~options.live_run
        quit force
    else
        return;
    end
else
    stage_1_running_jobs='';
    stage_2_running_jobs='';
    stage_3_running_jobs='';
    stage_4_running_jobs='';
    stage_5_running_jobs='';
    stage_5e_running_jobs='';
    if (~options.process_headfiles_only)
        if starting_point>=4
            fid_path.current='BOGUS_INPUT_FOR_DONE_WORK';
            data_mode='local';
        end
        %% STAGE1 Scheduling
        % extract fid
        if (starting_point <= 1 || ~islogical(options.CS_preview_data) )
            % when checking consistency, we only check volume 1
            % That is becuase we're making sure the fid is what we expect,
            % and that is a reasonable fingerprint.
            % Checking other volumes would require getting their data bits
            % first, and that is not likely to fail independently.
            %{
            if (local_or_streaming_or_static == 1)
                fid_consistency = write_or_compare_fid_tag(fid_path.current,recon_mat.fid_tag_file,1);
            else
                scanner_user='omega';
                fid_consistency = write_or_compare_fid_tag(fid_path.current,recon_mat.fid_tag_file,1,recon_mat.scanner_name,scanner_user);
            end
            %}
            if the_scanner.fid_consistency(fid_path.current,recon_mat.fid_tag_file)
                % Getting subvolume should be the job of volume setup.
                % TODO: Move get vol code into setup!
                if ~exist(work_subfolder,'dir')
                    % decided to let shis vol manager create its own work folder
                    % warning('  Creating work subfolder to fetch fid, this shouldn''t happen here. This only occurs in exotic testing or recovery conditions.');
                    mkdir(work_subfolder);
                end
                if recon_mat.nechoes == 1
                    % for multi-block fids(diffusion)
                    %if (local_or_streaming_or_static == 1)
                    %{
                    if strcmp(data_mode,'local')
                        get_subvolume_from_fid(fid_path.current,volume_fid,volume_number,recon_mat.bytes_per_block);
                    else
                        get_subvolume_from_fid(fid_path.current,volume_fid,volume_number,recon_mat.bytes_per_block,recon_mat.scanner_name,the_scanner.user);
                    end
                    %}
                    the_scanner.fid_get_block(fid_path.current,volume_fid,volume_number,recon_mat.bytes_per_block);
                elseif recon_mat.nechoes > 1 && volume_number == 1
                    % for 1 block fids, mgre, and single vol, in theory we
                    % can only operate when static, further we should only
                    % enter this code block if already static.
                    %
                    % This is coded to only trigger for multi-echo,
                    % Hopefully single vol will be handled correctly in necho 1 block above.
                    %
                    % schedule local gatekeeper on volume fid
                    % for volume 1 fetch fetch data, run the fid
                    % splitter.
                    error('needs update');
                    % due to how ugly puller_glusterpsaceCS_2 is we have to define yet another temply var.
                    % hopefully we can swap the proper terminal puller code
                    if ~exist('datapath','var')
                        datapath=['/home/mrraw/' recon_mat.scanner_patient '/' recon_mat.scanner_acquisition '.fid'];
                    end
                    local_fid= fullfile(recon_mat.study_workdir,'fid');
                    if ~exist(local_fid,'file')
                        error('untested after code update');
                        pull_cmd=sprintf('puller_simple -oer -u %s %s %s/%s.fid %s.work',...
                            options.scanner_user, recon_mat.scanner_name, recon_mat.scanner_patient,recon_mat.scanner_acquisition,runno);
                        [s,sout] = system(pull_cmd);
                        assert(s==0,sout);
                        %%% the replacement of puller_glusterspaceCS_2 was
                        %%% not tested yet.
                        puller_glusterspaceCS_2(recon_mat.runno,datapath,recon_mat.scanner_name,recon_mat.study_workdir,3);
                    end
                    if ~exist(local_fid,'file') 
                        % It is assumed that the target of puller is the local_fid
                        error_flag = 1;
                        log_msg =sprintf('Unsuccessfully attempt to pull file from scanner %s: %s. Dying now.\n',...
                            scanner,[datapath '/fid']);
                        yet_another_logger(log_msg,log_mode,log_file,error_flag);
                        if isdeployed; quit force; else; error(log_msg); end
                    end
                    % Run splitter
                    fs_slurm_options=struct;
                    fs_slurm_options.v=''; % verbose
                    fs_slurm_options.s=''; % shared; volume setup should to share resources.
                    fs_slurm_options.mem=50000; % memory requested; fs needs a significant amount; could do this smarter, though.
                    fs_slurm_options.p=cs_queue.full_volume; % For now, will use gatekeeper queue for volume manager as well
                    fs_slurm_options.job_name = [recon_mat.runno '_fid_splitter_recon'];
                    fs_slurm_options.reservation = active_reservation;
                    fs_args= sprintf('%s %s', local_fid,recon_file);
                    fs_cmd = sprintf('%s %s %s', cs_execs.fid_splitter,matlab_path,fs_args);
                    if ~options.live_run
                        fid_splitter_batch = fullfile(volume_dir, 'sbatch', [recon_mat.runno '_fid_splitter_CS_recon.bash']);
                        batch_file = create_slurm_batch_files(fid_splitter_batch,fs_cmd,fs_slurm_options);
                        %fid_splitter_running_jobs
                        stage_1_running_jobs = dispatch_slurm_jobs(batch_file,'');
                    else
                        eval(sprintf('fid_splitter_exec %s',fs_args));
                    end
                % else
                    % error('Trouble with nechoes detect switch tell dev they''re sloppy');
                end
            else
                log_mode = 1;
                error_flag = 1;
                log_msg = sprintf('Fid consistency failure at volume %s! source fid for (%s) is not the same source fid as the first volume''s fid.\n',volume_runno,fid_path.current);
                log_msg = sprintf('%sCan manual check with "write_or_compare_fid_tag(''%s'',''%s'',%i,''%s'',''%s'')"\n',...
                    log_msg,fid_path.current,recon_mat.fid_tag_file,volume_number,recon_mat.scanner_name,the_scanner.user);
                log_msg = sprintf('%sCRITICAL ERROR data_mode=%i\n',log_msg,data_mode);
                yet_another_logger(log_msg,log_mode,log_file,error_flag);
                if isdeployed; quit force; else error(log_msg); end
            end
        end
        %% STAGE2 Scheduling
        % setup volume
        if (starting_point <= 2 || ~islogical(options.CS_preview_data) )
            % Schedule setup
            %% Make variable file
            setup_var = matfile(setup_variables,'Writable',true);
            setup_var.recon_file = recon_file;
            setup_var.volume_number = volume_number;
            setup_var.volume_runno = volume_runno;
            setup_var.volume_dir = volume_dir;
            setup_var.volume_log_file = volume_log_file;
            setup_var.work_subfolder = work_subfolder;
            setup_var.volume_fid = volume_fid;
            setup_var.volume_workspace = volume_workspace;
            setup_var.temp_file = temp_file;
            setup_var.images_dir = images_dir;
            setup_var.headfile_path = headfile_path;
            %%% Schedule setup via slurm and record jobid for dependency scheduling.
            vsu_slurm_options=struct;
            vsu_slurm_options.v=''; % verbose
            vsu_slurm_options.s=''; % shared; volume setup should to share resources.
            vsu_slurm_options.mem=50000; % memory requested; vsu needs a significant amount; could do this smarter, though.
            vsu_slurm_options.p=cs_queue.full_volume; % For now, will use gatekeeper queue for volume manager as well
            vsu_slurm_options.job_name = [volume_runno '_volume_setup_for_CS_recon'];
            %vsu_slurm_options.reservation = active_reservation;
            % using a blank reservation to force no reservation for this job.
            vsu_slurm_options.reservation = '';
            volume_setup_batch = fullfile(volume_dir, 'sbatch', [ volume_runno '_volume_setup_for_CS_recon.bash']);
            vsu_args=sprintf('%s',setup_variables);
            vsu_cmd = sprintf('%s %s %s', cs_execs.volume_setup,matlab_path, vsu_args);
            if  stage_1_running_jobs
                dep_string = stage_1_running_jobs;
                dep_type = 'afterok-or';
            else
                dep_string = '';
                dep_type = '';
            end
            if ~options.live_run
                batch_file = create_slurm_batch_files(volume_setup_batch,vsu_cmd,vsu_slurm_options);
                stage_2_running_jobs = dispatch_slurm_jobs(batch_file,'',dep_string,dep_type);
            else
                a=strsplit(vsu_args);
                setup_volume_work_for_CSrecon_exec(a{:});clear a;
            end
        end
        if options.CS_preview_data
            return;
        end
        %% STAGE3 Scheduling
        % readout slices
        if (starting_point <= 3)
            %{
            % update itnlim from main mat file to our volume file...
            % but SERIOUSLY WHY!
            mf = matfile(variables_file,'Writable',true);
            rf = matfile(recon_file);
            rf_opts=rf.options;
            Itnlim = rf_opts.Itnlim;
            mf_opts=mf.options;
            mf_opts.Itnlim=Itnlim;
            mf.options=mf_opts;
            %}
            % Schedule slice jobs
            single_threaded_recon = 1;
            swr_slurm_options=struct;
            swr_slurm_options.v=''; % verbose
            if single_threaded_recon
                swr_slurm_options.c=1; % was previously 2...also need to investigate binding
                swr_slurm_options.hint='nomultithread';
                %{
            else
                swr_slurm_options.s='';
                swr_slurm_options.hint='multithread';
                %}
            end
            % We use mem limit to control the number of jobs per node.
            % Want to allow 32-40 jobs per node, but use --ntasks-per-core=1
            % to make sure that every core has exactly one job on them.
            % That is why this mem number gets to be constant, we shouldnt
            % run into trouble until CS_slices are very (VERY) large.
            swr_slurm_options.mem='5900';
            swr_slurm_options.p=cs_queue.recon;
            % swr_slurm_options.job_name=[volume_runno '_CS_recon_' num2str(chunk_size) '_slice' plural '_per_job'];
            swr_slurm_options.job_name=[volume_runno '_CS_recon_NS' num2str(options.chunk_size)];
            swr_slurm_options.reservation = active_reservation;
            slices_to_process = [];
            if exist(temp_file,'file')
                %Find slices that need to be reconned.
                % the temp file only exists if setup has run(and cleanup
                % has not)
                [tmp_header, work_done, not_done] = load_cstmp_hdr(temp_file);
                if ~options.keep_work
                    slices_to_process = find(~tmp_header);
                else
                    slices_to_process = find(tmp_header<options.Itnlim);
                end
            end
            if ~exist(temp_file,'file') || length(tmp_header) <= 2
                % no temp file, or it failed to load
                slices_to_process = 1:recon_mat.original_dims(1);
            end
            % if we have more than one element, or 1 element and its
            % non-zero
            if nnz(slices_to_process)
                num_chunks = ceil(length(slices_to_process)/options.chunk_size);
                log_msg =sprintf('Volume %s: Number of chunks (independent jobs): %i.\n',volume_runno,num_chunks);
                yet_another_logger(log_msg,log_mode,log_file);
                log_msg =sprintf('Volume %s: Number of slices to be reconstructed: %i.\n',volume_runno,nnz(~isnan(slices_to_process)));
                yet_another_logger(log_msg,log_mode,log_file);
                % pad slices_to_process out to num_chunks*chunk_size if not
                % even multiple.
                slice_pack_padding=options.chunk_size-mod(numel(slices_to_process),options.chunk_size);
                if slice_pack_padding~=options.chunk_size
                    slices_to_process(end+1:end+slice_pack_padding)=NaN;
                end
                zero_width = ceil(log10(recon_mat.dim_x+1));
                if options.slice_randomization
                    zero_width=ceil(log10(num_chunks+1));
                    slices_to_process=slices_to_process(randperm(numel(slices_to_process)));
                else 
                    options.slice_randomization=0;
                end
                s3jobs=cell(1,num_chunks);
                %slices to process would be better named chunks, or slabs.
                slices_to_process = reshape(slices_to_process,[options.chunk_size num_chunks]);
                % slice in this for loop would be better named chunk, or
                % slab
                % we could parfor this when we're in live_mode.
                for ch_num=1:num_chunks
                    %parfor ch_num=1:num_chunks
                    % extract this selection of slice indicies
                    sx=slices_to_process(:,ch_num);
                    %{
                    % NOTE: this algorithm never worked!
                    % start a string with the first number
                    slice_string = sprintf(['' '%0' num2str(zero_width) '.' num2str(zero_width) 's'] ,num2str(sx(1)));
                    % remove any nans we used to pad out the chunks
                    sx(isnan(sx))=[];
                    if length(sx)>3
                        no_con_test = sum(diff(diff(sx)));
                    else
                        no_con_test = 1;
                    end
                    for ss = 2:length(sx)
                        if (no_con_test)
                            slice_string = [slice_string '_' sprintf(['' '%0' num2str(zero_width) '.' num2str(zero_width) 's'] ,num2str(sx(ss)))];
                        elseif (ss==length(sx))
                            slice_string = [slice_string '_to_' sprintf(['' '%0' num2str(zero_width) '.' num2str(zero_width) 's'] ,num2str(sx(ss)))];
                        end
                    end;slice_string
                    %}
                    
                    % force single_range output
                    if ~options.slice_randomization
                        slice_ranges=range_condenser(sx,1);
                        fmt=sprintf('%%0%ii_to_%%0%ii',zero_width,zero_width);
                        slice_string=sprintf(fmt,slice_ranges{1}(1),slice_ranges{1}(end));
                    else 
                        slice_string=sprintf('%i ',sx);
                    end
                    swr_args= sprintf('%s %s %s',setup_variables, slice_string);
                    swr_cmd = sprintf('%s %s %s', cs_execs.slice_recon,matlab_path,swr_args);
                    if  stage_2_running_jobs
                        dep_string = stage_2_running_jobs;
                        dep_type = 'afterok-or';
                    else
                        dep_string = '';
                        dep_type = '';
                    end
                    c_running_jobs ='';
                    if ~options.live_run
                        if options.slice_randomization
                            fmt=sprintf('set_%%0%ii_rand%i',zero_width,options.chunk_size);
                            slice_string=sprintf(fmt,ch_num);
                        end
                        slicewise_recon_batch = fullfile(volume_dir, 'sbatch', [ volume_runno '_slice' slice_string '_CS_recon.bash']);
                        batch_file = create_slurm_batch_files(slicewise_recon_batch,swr_cmd,swr_slurm_options);
                        [c_running_jobs, msg1,msg2]= dispatch_slurm_jobs(batch_file,'',dep_string,dep_type);
                        s3jobs{ch_num}=c_running_jobs;
                        if msg1
                            disp(msg1)
                        end
                        if msg2
                            disp(msg2)
                        end
                    else
                        %eval(sprintf('slicewise_CSrecon_exec %s',swr_args));
                        cell_args=strsplit(slice_string);
                        slicewise_CSrecon_exec(setup_variables, cell_args{:});
                        %slicewise_CSrecon_exec(swr_args)
                        %starting_point=4;
                    end
                end
                if ~isempty(s3jobs) && ~options.live_run
                    stage_3_running_jobs=strjoin(s3jobs,':');
                    if strcmp(':',stage_3_running_jobs(1))
                        stage_3_running_jobs(1)=[];
                    end
                end
            end
        end
        %% STAGE4 Scheduling
        % volume_cleanup 
        if (starting_point <= 4)
            % Schedule via slurm and record jobid for dependency scheduling.
            vcu_slurm_options=struct;
            vcu_slurm_options.v=''; % verbose
            vcu_slurm_options.s=''; % shared; volume setup should to share resources.
            vcu_slurm_options.mem=66000; % memory requested; vcu needs a significant amount; could do this smarter, though.
            vcu_slurm_options.p=cs_queue.full_volume; % Really want this to be high_priority, and will usually be that.
            vcu_slurm_options.job_name =[volume_runno '_CS_recon_NS' num2str(options.chunk_size)];
            %vcu_slurm_options.reservation = active_reservation;
            % using a blank reservation to force no reservation for this job.
            vcu_slurm_options.reservation = ''; 
            volume_cleanup_batch = fullfile(volume_dir, 'sbatch', [ volume_runno '_volume_cleanup_for_CS_recon.bash']);
            vcu_args=sprintf('%s',setup_variables);
            vcu_cmd = sprintf('%s %s %s', cs_execs.volume_cleanup,matlab_path,vcu_args);
            if ~options.live_run
                batch_file = create_slurm_batch_files(volume_cleanup_batch,vcu_cmd,vcu_slurm_options);
                maybe_im_a_singleton='';
                if (stage_3_running_jobs)
                    maybe_im_a_singleton='singleton';
                end
                stage_4_running_jobs = dispatch_slurm_jobs(batch_file,'',maybe_im_a_singleton);
            else
                a=strsplit(vcu_args);
                volume_cleanup_for_CSrecon_exec(a{:});clear a;
                starting_point=5;
            end
        end
        %% STAGE5 Scheduling
        % send data to remote workstation and write completion flags
        if (starting_point <= 5)
            if ~options.keep_work
                warning('TODO finish shipper update');
                shipper_cmds=cs_recon_volume_transfer_commands();
                shipper_slurm_options=struct;
                shipper_slurm_options.v=''; % verbose
                shipper_slurm_options.s=''; % shared; volume manager needs to share resources.
                shipper_slurm_options.mem=500; % memory requested; shipper only needs a miniscule amount.
                shipper_slurm_options.p=cs_queue.gatekeeper; % For now, will use gatekeeper queue for volume manager as well
                shipper_slurm_options.job_name = [volume_runno '_ship_to_' remote_workstation.name];
                %shipper_slurm_options.reservation = active_reservation;
                % using a blank reservation to force no reservation for this job.
                shipper_slurm_options.reservation = '';
                shipper_batch = fullfile(volume_dir, 'sbatch', [ volume_runno '_shipper.bash']);
                %batch_file = create_slurm_batch_files(shipper_batch,{rm_previous_flag,local_size_cmd remote_size_cmd eval_cmd},shipper_slurm_options);
                if ~exist(flag_success,'file') && numel(shipper_cmds)>0
                    batch_file = create_slurm_batch_files(shipper_batch,shipper_cmds,shipper_slurm_options);
                    dep_status='';
                    if ~options.live_run
                        if stage_4_running_jobs
                            dep_status='afterok-or';
                        end
                        stage_5_running_jobs = dispatch_slurm_jobs(batch_file,'',stage_4_running_jobs,dep_status);
                    else
                        [ship_st,ship_out]=system(sprintf('bash %s',batch_file));
                        if ship_st~=0
                            error(ship_out);
                        end
                    end
                else
                    ship_st=0;
                    fprintf('Images previously sent successfully.\n');
                end
            end
        end
    end
    %% STAGE5+ Scheduling
    % data has been sent to remote workstation, we just neeed to finish meta-data
    %if (starting_point >= 5)%(starting_point <= 6)
    if (starting_point == 5)%(starting_point <= 6)
        % This is only scheduled at stage 5 because prior to that it wont
        % work anyway.
        % originally it was embedded in stage 5 scheduling, however somehow
        % it kept leeking jobs... Adjusted to timeout after 3 minutes
        % now(internal to the handlers function) 
        %if ~options.live_run
        if strcmp(the_scanner.vendor,'agilent')
            stage_5e_running_jobs = deploy_procpar_handlers(setup_variables);
        else
            error('incomplete');
        end
        %else
        %% live run starting point advance handling
        % this prevents volume manager from running
        % recursively forever.
        if options.live_run && exist('ship_st','var') && ship_st==0
            starting_point=6;
        end
        %end
    end
    
    % Why is volume manager only re-scheduled if we have stage 4(cleanup)
    % jobs? That seems like a clear mistake! We should be rescheduling so
    % long as we're not stage 6. 
    % AND we should be dependent on all the rest of the jobs having
    % terminated eg, dependency=afterany. SO, we should update this code to
    % build a running list of jobs to be scheduled behind.
    %if stage_4_running_jobs
    % when we keep work, we never finish stage 5 because we never send
    % data.
    % That seems okay, so lets watch for that, and not re_schedule volume
    % manager when keep_work is on and stage is 5+
    %{
    if ( ~options.keep_work && starting_point < 6 ) ...
            || ( options.keep_work &&  starting_point < 5 )
    %}
    % clever simplificaion of conditional.
    if starting_point < ( 6 - options.keep_work)
        vm_slurm_options=struct;
        vm_slurm_options.v=''; % verbose
        vm_slurm_options.s=''; % shared; volume manager needs to share resources.
        vm_slurm_options.mem=2048; % memory requested; vm only needs a miniscule amount.
            %--In theory only! For yz-array sizes > 2048^2, loading the
            % data of phmask, CSmask, etc can push the memory of 512 MB
        vm_slurm_options.p=cs_queue.full_volume; % For now, will use gatekeeper queue for volume manager as well
        vm_slurm_options.job_name = [volume_runno '_volume_manager'];
        %vm_slurm_options.reservation = active_reservation;
        % using a blank reservation to force no reservation for this job.
        vm_slurm_options.reservation = '';
        volume_manager_batch = fullfile(volume_dir, 'sbatch', [ volume_runno '_volume_manager.bash']);
        vm_args=sprintf('%s %s %i %s',recon_file,volume_runno, volume_number,recon_mat.study_workdir);
        vm_cmd = sprintf('%s %s %s', cs_execs.volume_manager,matlab_path, vm_args);
        if ~options.live_run
            batch_file = create_slurm_batch_files(volume_manager_batch,vm_cmd,vm_slurm_options);
            %{
            if stage_4_running_jobs
                c_running_jobs = dispatch_slurm_jobs(batch_file,'',stage_4_running_jobs,'afternotok');
            elseif stage_5_running_jobs
            end
            %}
            %% re-configured to run as singleton unless we scheduled endstage jobs. 
            % when we schecdule end stage jobs, tell ourselves to run one
            % more time once they're terminated, note not after failure, or
            % after success.
            dep_type='singleton';
            dep_jobs='';
            if ~isempty(stage_4_running_jobs) || ~isempty(stage_5_running_jobs) || ~isempty(stage_5e_running_jobs)
                dep_type='afterany';
                %%% these can be combined with strjoin. 
                job_glob=cell(0);
                if stage_5e_running_jobs
                    job_glob=[job_glob,stage_5e_running_jobs];
                    %dep_jobs=stage_5e_running_jobs;
                end
                if stage_5_running_jobs
                    job_glob=[job_glob,stage_5_running_jobs];
                    %dep_jobs=sprintf('%s:%s',dep_jobs,stage_5_running_jobs);
                end
                if stage_4_running_jobs
                    job_glob=[job_glob,stage_4_running_jobs];
                    %dep_jobs=sprintf('%s:%s',dep_jobs,stage_4_running_jobs);
                end
                %{
                if strcmp(dep_jobs(1),':')
                    dep_jobs(1)=[];
                end
                %}
                dep_jobs=strjoin(job_glob,':');
            end
            c_running_jobs = dispatch_slurm_jobs(batch_file,'',dep_jobs,dep_type);
            dep_feedback=dep_type;
            if ~isempty(dep_jobs)
                dep_feedback=sprintf('%s:%s',dep_feedback,dep_jobs);
            end
            log_mode = 1;
            log_msg =sprintf('volume %s volume_manager re-initialize after dependency %s satisfied until complete. Next SLURM jobid(s): %s.\n',volume_runno,dep_feedback,c_running_jobs);
            yet_another_logger(log_msg,log_mode,log_file);
        else
            % could add dbstack check to prevent infinite recursion and
            % stack overflow like behavior.
            % maybe max out at 50? 
            eval(sprintf('volume_manager_exec %s',vm_args));
            pause(1);
        end
    end
    if starting_point == 6
        volume_clean(setup_variables);
    end
end


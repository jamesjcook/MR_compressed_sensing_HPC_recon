function [dim_y, dim_z, n_sampled_lines, sampling_fraction, mask, ...
    CSpdf, phmask, recon_dims, original_mask, original_pdf, original_dims]= ...
    process_CS_mask(procpar_or_CStable, dim_x, options)
% function process_CS_mask 
fprintf('process_CS_mask ... this can take a minute.\n');

[mask, dim_y, dim_z, pa, pb, cs_factor ] = extract_info_from_CStable(procpar_or_CStable);
dim_2=dim_y;
dim_3=dim_z;
dim_2=size(mask,1);
dim_3=size(mask,2);
sampling_fraction = 1/cs_factor;

%{
n_sampled_lines=nnz(mask);
sampling_fraction = n_sampled_lines/length(mask(:));
%}
% Generate sampling PDF (this is NOT the sampling mask)
[CSpdf,~] = genPDF_wn_v2([dim_2, dim_3],pa,sampling_fraction,pb,false);
original_mask = mask;
original_pdf = CSpdf;

% detect non-power of 2, or non-square, then pad
% (up to 2^64 becuase that should forever be plenty, and a while loop
% woudld be less cool)
max_pow_2=64;
dyadic_idx = 2.^(1:max_pow_2);
pidx = find(max([dim_2, dim_3])<=dyadic_idx,1);
p = dyadic_idx(pidx);
if p > max([dim_2, dim_3])
    mask = padarray(original_mask,[p-dim_2 p-dim_3]/2,0,'both');
    %pad with 1's since we don't want to divide by zero later
    % is this our error when non-power of 2 recon? the CSpdf should be
    % re-normalized to incorporate the new points? Potentially by padding
    % with min_float?
    CSpdf = padarray(CSpdf,[p-dim_2 p-dim_3]/2,1,'both'); 
end
original_dims = double([dim_x dim_y dim_z]);
recon_dims = [original_dims(1) size(mask)];%size(data);

%mask to grab center frequency
phmask = zpad(hamming(options.hamming_window)*hamming(options.hamming_window)', ...
    size(mask,1), size(mask,2));
%for low-order phase estimation and correction
phmask = phmask/max(phmask(:));
end

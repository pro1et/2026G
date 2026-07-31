function verify_measurement_window_results
% Verify RTL decimation and Q1.15 periodic-Hann arithmetic sample by sample.

scriptDir = fileparts(mfilename('fullpath'));
fpgaDir = fileparts(scriptDir);
resultDir = fullfile(fpgaDir, 'sim_results');

fir = readtable(fullfile(resultDir, 'window_pipeline_fir.csv'));
decim = readtable(fullfile(resultDir, 'window_pipeline_decim.csv'));
actualWindow = readtable(fullfile(resultDir, 'window_pipeline_window.csv'));

assert(height(fir) == 65536, 'Expected 65536 FIR samples, got %d.', height(fir));
assert(height(decim) == 4096, 'Expected 4096 decimated samples, got %d.', height(decim));
assert(height(actualWindow) == 4096, 'Expected 4096 window samples, got %d.', height(actualWindow));

expectedDecim = int16(fir.data(1:16:end));
decimActual = int16(decim.data);
decimError = int32(decimActual) - int32(expectedDecim);

coePath = fullfile(fpgaDir, 'src', 'ip', 'hann_4096_half_q15.coe');
coeText = fileread(coePath);
vectorToken = regexp(coeText, 'memory_initialization_vector\s*=\s*([^;]+);', ...
    'tokens', 'once', 'ignorecase');
assert(~isempty(vectorToken), 'Could not parse Hann COE vector.');
hexTokens = regexp(vectorToken{1}, '[0-9A-Fa-f]+', 'match');
halfCoefficients = int32(hex2dec(char(hexTokens)));
assert(numel(halfCoefficients) == 2048, ...
    'Expected 2048 half-window coefficients, got %d.', numel(halfCoefficients));
coefficients = [halfCoefficients; int32(32767); flipud(halfCoefficients(2:end))];

product = int64(decimActual) .* int64(coefficients);
bias = int64(16384) * ones(4096, 1, 'int64');
bias(product < 0) = int64(16383);
expectedWindow = int16(floor(double(product + bias) / 32768));
windowActual = int16(actualWindow.data);
windowError = int32(windowActual) - int32(expectedWindow);

maxDecimError = max(abs(decimError));
maxWindowError = max(abs(windowError));
decimMismatchCount = nnz(decimError);
windowMismatchCount = nnz(windowError);

comparison = table((0:4095)', int32(decimActual), coefficients, ...
    int32(expectedWindow), int32(windowActual), windowError, ...
    'VariableNames', {'index','decim_data','hann_q15','expected_window', ...
                      'rtl_window','error'});
writetable(comparison, fullfile(resultDir, 'window_matlab_comparison.csv'));

reportPath = fullfile(resultDir, 'window_matlab_verification.txt');
report = fopen(reportPath, 'w');
assert(report ~= -1, 'Cannot create MATLAB verification report.');
fprintf(report, 'fir_sample_count=%d\n', height(fir));
fprintf(report, 'decim_sample_count=%d\n', height(decim));
fprintf(report, 'window_sample_count=%d\n', height(actualWindow));
fprintf(report, 'decim_mismatch_count=%d\n', decimMismatchCount);
fprintf(report, 'decim_max_abs_error_lsb=%d\n', maxDecimError);
fprintf(report, 'window_mismatch_count=%d\n', windowMismatchCount);
fprintf(report, 'window_max_abs_error_lsb=%d\n', maxWindowError);
if decimMismatchCount == 0 && windowMismatchCount == 0
    verificationResult = 'PASS';
else
    verificationResult = 'FAIL';
end
fprintf(report, 'result=%s\n', verificationResult);
fclose(report);

fig = figure('Visible', 'off', 'Color', 'w', 'Position', [100 100 1200 720]);
tiledlayout(2, 1);
nexttile;
plot(double(windowActual), 'b'); hold on;
plot(double(expectedWindow), '--r'); grid on;
xlabel('Sample index'); ylabel('S16 code');
title('RTL and MATLAB Q1.15 Hann-window output');
legend('RTL', 'MATLAB fixed-point reference');
nexttile;
stem(double(windowError), 'filled', 'MarkerSize', 2); grid on;
xlabel('Sample index'); ylabel('Error (LSB)');
title(sprintf('Pointwise error: mismatches=%d, max |error|=%d LSB', ...
    windowMismatchCount, maxWindowError));
exportgraphics(fig, fullfile(resultDir, 'window_matlab_verification.png'), ...
    'Resolution', 150);
close(fig);

assert(decimMismatchCount == 0, ...
    'Downsampling mismatch: %d points, max error %d LSB.', ...
    decimMismatchCount, maxDecimError);
assert(windowMismatchCount == 0, ...
    'Hann mismatch: %d points, max error %d LSB.', ...
    windowMismatchCount, maxWindowError);
fprintf('MATLAB VERIFICATION PASSED: 4096/4096 samples exactly match RTL.\n');
end

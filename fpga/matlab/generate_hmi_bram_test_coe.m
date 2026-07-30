%% Generate HMI BRAM test data and COE files
%
% Test signal:
%   sine wave, 10 kHz, 100 mVpp (50 mV peak)
%
% Physical BRAM word width:
%   32 bit on both ports
%
% Header fields each occupy one complete 32-bit BRAM word.  Only waveform
% and spectrum plot points are packed two 16-bit values per 32-bit word:
%   word[15:0]  = point[2*i]
%   word[31:16] = point[2*i+1]
%
% No additional toolbox is required.

clear;
clc;

%% Fixed system parameters
adcFsHz = 32e6;
fftDecimation = 16;
fftFsHz = adcFsHz / fftDecimation;
fftSize = 4096;

timeSampleCount = 32768;
spectrumPointCount = 1024;

signalFrequencyHz = 10e3;
signalVppMv = 100;
signalPeakMv = signalVppMv / 2;

% HMI-only test calibration. The real system will replace this with the
% measured ADC/front-end calibration in PS software.
mvPerRawCode = 1.0;
signalPeakRaw = signalPeakMv / mvPerRawCode;

% AXI-side physical BRAM depths, in 32-bit Port A words.
timePortAWordDepth = 32768;
spectrumPortAWordDepth = 1024;

%% Output directories
scriptDir = fileparts(mfilename('fullpath'));
fpgaDir = fileparts(scriptDir);

coeDir = fullfile(fpgaDir, 'src', 'ip', 'hmi_bram');
resultDir = fullfile(scriptDir, 'results', 'hmi_bram_test');

if ~exist(coeDir, 'dir')
    mkdir(coeDir);
end
if ~exist(resultDir, 'dir')
    mkdir(resultDir);
end

%% Generate 32768 time-domain samples at 32 MHz
timeIndex = (0:timeSampleCount-1).';
timeSamplesDouble = signalPeakRaw .* sin( ...
    2*pi*signalFrequencyHz*timeIndex/adcFsHz);
timeSamples = int16(round(timeSamplesDouble));

vppRaw = uint16(double(max(timeSamples)) - double(min(timeSamples)));

% The PL/PS protocol stores mean square, not the square accumulator.
% Use the theoretical value in this HMI test header so that the displayed
% value is exactly 50/sqrt(2) mV before decimal formatting.
vrmsSqRaw = uint32(round((signalPeakRaw^2) / 2));
vrmsRaw = sqrt(double(vrmsSqRaw));

f1Hz = uint32(signalFrequencyHz);

assert(vppRaw == uint16(100), ...
    'The generated quantized waveform does not have the expected 100-code Vpp.');

%% Build Time BRAM 32-bit image
%
% W0       Vpp_raw, U32
% W1       Vrms_sq_raw, U32
% W2       f1_hz, U32
% W3       sample_count, U32
% W4...    32768 signed time samples, two S16 values per word

timeHeaderWords = 4;
timeData16 = signed_i16_to_u16(timeSamples);
timeDataWords32 = pack_u16_pairs(timeData16);
timeUsedWords32 = timeHeaderWords + numel(timeDataWords32);

assert(timeUsedWords32 <= timePortAWordDepth, ...
    'Time image exceeds the configured Port A depth.');

timeWords32 = zeros(timePortAWordDepth, 1, 'uint32');
timeWords32(1) = uint32(vppRaw);
timeWords32(2) = vrmsSqRaw;
timeWords32(3) = f1Hz;
timeWords32(4) = uint32(timeSampleCount);
timeWords32(5:timeUsedWords32) = timeDataWords32;

%% Generate the FFT input: 65536 ADC samples -> decimate by 16 -> 4096
fftAdcSampleCount = fftSize * fftDecimation;
fftAdcIndex = (0:fftAdcSampleCount-1).';
fftAdcSamples = signalPeakRaw .* sin( ...
    2*pi*signalFrequencyHz*fftAdcIndex/adcFsHz);

% For this single 10 kHz test tone, direct decimation is sufficient.
% The real PL path must use its anti-alias FIR before this operation.
fftInput = fftAdcSamples(1:fftDecimation:end);
assert(numel(fftInput) == fftSize, ...
    'Decimated FFT input length is not 4096.');

% Symmetric Hamming window, implemented directly to avoid toolbox
% dependencies.
windowIndex = (0:fftSize-1).';
hammingWindow = 0.54 - 0.46*cos(2*pi*windowIndex/(fftSize-1));
windowedInput = fftInput .* hammingWindow;

fftResult = fft(windowedInput, fftSize);
powerFull = abs(fftResult).^2;
powerKept = powerFull(1:spectrumPointCount);

% The 16-bit spectrum array is for relative HMI plotting. Normalize the
% largest retained power bin to 65535.
maxPower = max(powerKept);
assert(maxPower > 0, 'Generated spectrum is all zero.');
spectrumPoints = uint16(round(powerKept ./ maxPower .* 65535));

fftBinWidthHz = fftFsHz / fftSize;
keptMaxFrequencyHz = (spectrumPointCount - 1) * fftBinWidthHz;

%% Build Spectrum BRAM 32-bit image
%
% W0       peak_count, U32
% W1       f1 frequency, U32
% W2       f1 linear peak amplitude, U32
% W3       f2 frequency, U32
% W4       f2 amplitude, U32
% W5       f3 frequency, U32
% W6       f3 amplitude, U32
% W7       spectrum_count, U32
% W8...    1024 spectrum power points, two U16 values per word

spectrumHeaderWords = 8;
spectrumDataWords32 = pack_u16_pairs(spectrumPoints);
spectrumUsedWords32 = spectrumHeaderWords + numel(spectrumDataWords32);

assert(spectrumUsedWords32 <= spectrumPortAWordDepth, ...
    'Spectrum image exceeds the configured Port A depth.');

spectrumWords32 = zeros(spectrumPortAWordDepth, 1, 'uint32');
spectrumWords32(1) = uint32(1);             % peak_count
spectrumWords32(2) = f1Hz;
spectrumWords32(3) = uint32(signalPeakRaw); % a1_raw
% W3...W6 remain zero because this is a single-frequency test.
spectrumWords32(8) = uint32(spectrumPointCount);
spectrumWords32(9:spectrumUsedWords32) = spectrumDataWords32;

%% Verify the packed plot-data portions
timeRoundTrip = unpack_u32_to_u16( ...
    timeWords32(timeHeaderWords+1:timeUsedWords32));
spectrumRoundTrip = unpack_u32_to_u16( ...
    spectrumWords32(spectrumHeaderWords+1:spectrumUsedWords32));

assert(isequal(timeRoundTrip, timeData16), ...
    'Time BRAM 32-bit packing verification failed.');
assert(isequal(spectrumRoundTrip, spectrumPoints), ...
    'Spectrum BRAM 32-bit packing verification failed.');

%% Write COE files for 32-bit Port A
timeCoePath = fullfile(coeDir, 'time_bram_10khz_100mvpp.coe');
spectrumCoePath = fullfile(coeDir, ...
    'spectrum_bram_10khz_100mvpp.coe');

write_coe32(timeCoePath, timeWords32);
write_coe32(spectrumCoePath, spectrumWords32);

%% Write human-readable 32-bit BRAM maps
write_hex32(fullfile(resultDir, 'time_bram_words32.txt'), ...
    timeWords32(1:timeUsedWords32));
write_hex32(fullfile(resultDir, 'spectrum_bram_words32.txt'), ...
    spectrumWords32(1:spectrumUsedWords32));

%% Write CSV files for independent inspection
timeCsvPath = fullfile(resultDir, 'time_samples.csv');
timeFile = fopen(timeCsvPath, 'w');
assert(timeFile >= 0, 'Cannot open time CSV output.');
timeCleanup = onCleanup(@() fclose(timeFile));
fprintf(timeFile, 'index,time_s,raw_code,mV\n');
for k = 1:timeSampleCount
    fprintf(timeFile, '%d,%.12g,%d,%.12g\n', ...
        k-1, (k-1)/adcFsHz, timeSamples(k), ...
        double(timeSamples(k))*mvPerRawCode);
end
clear timeCleanup;

spectrumCsvPath = fullfile(resultDir, 'spectrum_points.csv');
spectrumFile = fopen(spectrumCsvPath, 'w');
assert(spectrumFile >= 0, 'Cannot open spectrum CSV output.');
spectrumCleanup = onCleanup(@() fclose(spectrumFile));
fprintf(spectrumFile, 'bin,frequency_hz,power_u16\n');
for k = 1:spectrumPointCount
    fprintf(spectrumFile, '%d,%.12g,%u\n', ...
        k-1, (k-1)*fftBinWidthHz, spectrumPoints(k));
end
clear spectrumCleanup;

%% Save a visual reference image
referenceFigure = figure('Visible', 'off', 'Color', 'w');

subplot(2, 1, 1);
onePeriodSamples = round(adcFsHz / signalFrequencyHz);
plot((0:onePeriodSamples-1)/adcFsHz*1e6, ...
    double(timeSamples(1:onePeriodSamples))*mvPerRawCode, ...
    'LineWidth', 1.2);
grid on;
xlabel('Time (\mus)');
ylabel('Voltage (mV)');
title('Time BRAM reference: one 10 kHz period');

subplot(2, 1, 2);
plot((0:spectrumPointCount-1)*fftBinWidthHz/1e3, ...
    double(spectrumPoints), 'LineWidth', 1.2);
grid on;
xlabel('Frequency (kHz)');
ylabel('Normalized power (U16)');
title('Spectrum BRAM reference: bins 0 to 1023');
xlim([0 keptMaxFrequencyHz/1e3]);

referencePngPath = fullfile(resultDir, 'hmi_bram_reference.png');
exportgraphics(referenceFigure, referencePngPath, 'Resolution', 150);
close(referenceFigure);

%% Write generation summary
summaryPath = fullfile(resultDir, 'generation_summary.txt');
summaryFile = fopen(summaryPath, 'w');
assert(summaryFile >= 0, 'Cannot open summary output.');
summaryCleanup = onCleanup(@() fclose(summaryFile));

fprintf(summaryFile, 'HMI BRAM COE generation summary\n');
fprintf(summaryFile, 'ADC sample rate: %.0f Hz\n', adcFsHz);
fprintf(summaryFile, 'Signal frequency: %.0f Hz\n', signalFrequencyHz);
fprintf(summaryFile, 'Signal Vpp: %.6f mV\n', signalVppMv);
fprintf(summaryFile, 'Signal peak: %.6f mV\n', signalPeakMv);
fprintf(summaryFile, 'Vrms from header: %.9f mV\n', ...
    vrmsRaw*mvPerRawCode);
fprintf(summaryFile, 'Vrms squared raw: %u\n', vrmsSqRaw);
fprintf(summaryFile, 'Time samples: %d\n', timeSampleCount);
fprintf(summaryFile, 'Time Port A words used: %d of %d\n', ...
    timeUsedWords32, timePortAWordDepth);
fprintf(summaryFile, 'FFT sample rate after decimation: %.0f Hz\n', ...
    fftFsHz);
fprintf(summaryFile, 'FFT size: %d\n', fftSize);
fprintf(summaryFile, 'FFT bin width: %.9f Hz\n', fftBinWidthHz);
fprintf(summaryFile, 'Spectrum points: %d\n', spectrumPointCount);
fprintf(summaryFile, 'Highest stored frequency: %.9f Hz\n', ...
    keptMaxFrequencyHz);
fprintf(summaryFile, 'Spectrum Port A words used: %d of %d\n', ...
    spectrumUsedWords32, spectrumPortAWordDepth);
fprintf(summaryFile, 'Time COE: %s\n', timeCoePath);
fprintf(summaryFile, 'Spectrum COE: %s\n', spectrumCoePath);
clear summaryCleanup;

fprintf('\nHMI BRAM test data generated successfully.\n');
fprintf('Time COE:     %s\n', timeCoePath);
fprintf('Spectrum COE: %s\n', spectrumCoePath);
fprintf('Reference:    %s\n', referencePngPath);
fprintf('Vpp:          %.3f mV\n', double(vppRaw)*mvPerRawCode);
fprintf('Vrms:         %.6f mV\n', vrmsRaw*mvPerRawCode);
fprintf('f1:           %u Hz\n', f1Hz);
fprintf('FFT bin:      %.9f Hz\n', fftBinWidthHz);
fprintf('Spectrum max: %.9f kHz\n\n', keptMaxFrequencyHz/1e3);

%% Local helper functions

function values = signed_i16_to_u16(signedValues)
    values = uint16(mod(int32(signedValues), int32(65536)));
end

function words = pack_u16_pairs(halfwords)
    assert(mod(numel(halfwords), 2) == 0, ...
        'Halfword count must be even.');
    low = uint32(halfwords(1:2:end));
    high = bitshift(uint32(halfwords(2:2:end)), 16);
    words = bitor(low, high);
end

function halfwords = unpack_u32_to_u16(words)
    halfwords = zeros(numel(words)*2, 1, 'uint16');
    halfwords(1:2:end) = uint16(bitand(words, uint32(65535)));
    halfwords(2:2:end) = uint16(bitshift(words, -16));
end

function write_coe32(path, words)
    file = fopen(path, 'w');
    assert(file >= 0, 'Cannot open COE output: %s', path);
    cleanup = onCleanup(@() fclose(file));

    fprintf(file, 'memory_initialization_radix=16;\n');
    fprintf(file, 'memory_initialization_vector=\n');

    for k = 1:numel(words)
        if k < numel(words)
            fprintf(file, '%08X,\n', words(k));
        else
            fprintf(file, '%08X;\n', words(k));
        end
    end

    clear cleanup;
end

function write_hex32(path, words)
    file = fopen(path, 'w');
    assert(file >= 0, 'Cannot open 32-bit reference output: %s', path);
    cleanup = onCleanup(@() fclose(file));

    fprintf(file, 'word_address,byte_offset,hex32\n');
    for k = 1:numel(words)
        fprintf(file, '%d,0x%08X,%08X\n', k-1, (k-1)*4, words(k));
    end

    clear cleanup;
end

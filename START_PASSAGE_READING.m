function START_PASSAGE_READING
% START_PASSAGE_READING - Launcher for the intraoperative/preop passage reading task.
%
% Builds the cfg struct -> prepares paths, output folders, and BIDS filenames
% -> optionally starts audio recording and Ripple xippmex hardware ->
% launches task_reading(cfg).

cfg = struct();

%% ---------------- Subject / session ----------------
cfg.SUBJECT = 'qqq';      % default for test runs
% cfg.SUBJECT = 'DM1063';

% cfg.SESSION = 'preop';
cfg.SESSION = 'intraop';

%% ---------------- Stimulus & display parameters ----------------
cfg.stim_file                   = 'SLD_elicitation_passages.docx'; % supports .docx, .rtf, .txt, .md, .html, .pdf, .doc
cfg.stim_font_size              = 80;     % default matches START_METRO.m (reduce e.g. 40-55 for dense paragraphs)
cfg.stim_font_name              = get(0, 'DefaultAxesFontName'); % default matches task_metro.m ('Helvetica')
cfg.stim_font_weight            = 'bold'; % default matches task_metro.m
cfg.text_color                  = [1 1 1]; % default white (RGB 0..1)
cfg.background_color            = [0 0 0]; % default black (RGB 0..1)
cfg.screen_proportion           = 0.8;    % 0..1 proportion of screen used; buffers proportional to aspect ratio
cfg.max_sentences_per_paragraph = 3;      % split paragraphs longer than this (by periods) with extra line spacing

%% ---------------- Task metadata ----------------
cfg.TASK          = 'reading';          % BIDS task code
cfg.TASK_VERSION  = 1;
cfg.TASK_FUNCTION = 'task_reading.m';   % main task file; lives in <PATH_TASK>/scripts

%% ---------------- Session-specific settings ----------------
switch cfg.SESSION
    case 'preop'
        cfg.DIGOUT = 0;
    case 'intraop'
        cfg.DIGOUT = 1;
    otherwise
        error('Unknown session label: %s', cfg.SESSION);
end

clc
close all force

%% ---------------- Paths & output folders ----------------
computer_name = char(java.net.InetAddress.getLocalHost.getHostName);
switch computer_name
    case 'BML-ALIENWARE2'                                    % intraop rig laptop
        cfg.PATH_TASK       = 'D:\Task\Task_PassageReading';
        cfg.PATH_SOURCEDATA = 'D:\DBS\sourcedata';
        cfg.RECORD_AUDIO    = 1;

    case {'677-GUE-WL-0010','677-GUE-WL-0012','amsmeier'}    % AM Thinkpad X1 / strix laptops
        cfg.PATH_TASK       = 'C:\docs\code\Task_PassageReading';
        cfg.PATH_SOURCEDATA = 'C:\sourcedata';
        cfg.RECORD_AUDIO    = 1;

    case '677-GUE-WD-0013'                                   % Guenther lab soundbooth computer
        cfg.PATH_TASK       = 'C:\Task_PassageReading';
        cfg.PATH_SOURCEDATA = 'C:\Task_PassageReading_sourcedata';
        cfg.RECORD_AUDIO    = 1;

    case 'crc-dot1x-nat-10-239-35-5.bu.edu'
        cfg.PATH_TASK       = '/Users/kiendang/Documents/GitHub/Task_PassageReading';
        cfg.PATH_SOURCEDATA = '/Users/kiendang/Documents/Guenther_Lab_Data';
        cfg.RECORD_AUDIO    = 0;

    otherwise
        warning('Unrecognized host "%s" - using fallback paths.', computer_name);
        cfg.PATH_TASK       = '~/git/Task_PassageReading';
        cfg.PATH_SOURCEDATA = '~/Data/DBS/sourcedata';
        cfg.RECORD_AUDIO    = 0;
end
cfg.PATH_STIMDIR = fullfile(cfg.PATH_TASK, 'stimuli');

% Build subject/session-level BIDS folders
cfg.PATH_SUB      = fullfile(cfg.PATH_SOURCEDATA, ['sub-' cfg.SUBJECT]);
cfg.PATH_SES      = fullfile(cfg.PATH_SUB, ['ses-' cfg.SESSION]);
cfg.PATH_AUDIO    = fullfile(cfg.PATH_SES, 'audio');
cfg.PATH_SRC_TASK = fullfile(cfg.PATH_SES, 'task');

%% ---------------- Run basename, filenames ----------------
fileBaseName = ['sub-' cfg.SUBJECT '_ses-' cfg.SESSION '_task-' cfg.TASK '_run-'];

% Increment run ID based on existing event files for this session
allEventFiles = dir(fullfile(cfg.PATH_SRC_TASK, [fileBaseName '*_events.tsv']));
if ~isempty(allEventFiles)
    prevRunIds = regexp({allEventFiles.name}, '_run-(\d+)_', 'tokens', 'ignorecase');
    prevRunIds = cellfun(@(x) str2double(x{1,1}), prevRunIds, 'UniformOutput', true);
    runId = max(prevRunIds) + 1;
else
    runId = 1;
end

cfg.RUN_ID           = runId;
cfg.BASE_NAME        = [fileBaseName, sprintf('%02d_', runId)];
cfg.LOG_FILENAME     = fullfile(cfg.PATH_SRC_TASK, [cfg.BASE_NAME 'log.txt']);
cfg.EVENT_FILENAME   = fullfile(cfg.PATH_SRC_TASK, [cfg.BASE_NAME 'events.tsv']);
cfg.STIM_FILENAME    = fullfile(cfg.PATH_SRC_TASK, [cfg.BASE_NAME 'stim.tsv']);
cfg.PASSAGE_FILENAME = fullfile(cfg.PATH_SRC_TASK, [cfg.BASE_NAME 'full-passage.rtf']);
cfg.CFG_FILENAME     = fullfile(cfg.PATH_SRC_TASK, [cfg.BASE_NAME 'cfg.json']);
cfg.AUDIO_FILENAME   = fullfile(cfg.PATH_AUDIO,    [cfg.BASE_NAME(1:end-1) '.wav']);

%% ---------------- Create output directories ----------------
dirs_to_make = {cfg.PATH_SUB, cfg.PATH_SES, cfg.PATH_AUDIO, cfg.PATH_SRC_TASK};
for i = 1:numel(dirs_to_make)
    if ~isfolder(dirs_to_make{i})
        mkdir(dirs_to_make{i});
    end
end

%% ---------------- Diary (console logging) ----------------
diary(cfg.LOG_FILENAME);
oc = onCleanup(@() diary('off')); %#ok<NASGU>
disp(cfg);

%% ---------------- Change to scripts folder ----------------
scriptPath = fullfile(cfg.PATH_TASK, 'scripts');
if ~isfolder(scriptPath)
    error('Scripts folder not found: %s', scriptPath);
end
cd(scriptPath);
addpath(cfg.PATH_TASK, scriptPath);

%% ---------------- Start audio recording (optional) ----------------
if cfg.RECORD_AUDIO
    have_pct = exist('parpool','file') > 0 && exist('parfeval','file') > 0;
    have_lab = exist('record_audio','file') == 2;

    if have_pct && have_lab
        if isempty(gcp())
            parpool('local', 1);
        end
        workerQueueConstant = parallel.pool.Constant(@parallel.pool.PollableDataQueue);
        workerQueueClient   = fetchOutputs(parfeval(@(x) x.Value, 1, workerQueueConstant));

        future = parfeval(@record_audio, 1, cfg.AUDIO_FILENAME, workerQueueConstant);
        future.Diary; %#ok<NASGU>
        audioCleanup = onCleanup(@() send(workerQueueClient, 'stop')); %#ok<NASGU>
    else
        if ~have_lab
            warning('record_audio.m not found - using laptop audiorecorder fallback.');
        elseif ~have_pct
            warning('Parallel Computing Toolbox unavailable - using laptop audiorecorder fallback.');
        end
        audioCleanup = record_audio_laptop_only(cfg.AUDIO_FILENAME); %#ok<NASGU>
    end
end

%% ---------------- Ripple neurophysiology hardware (optional) ----------------
if exist('xippmex','file') == 3
    try
        digout = xippmex();
        cfg.DIGOUT = digout ~= 0;
        xippmexCleanup = onCleanup(@() xippmex('close')); %#ok<NASGU>
    catch err
        warning('xippmex init failed (%s) - disabling DIGOUT.', err.message);
        cfg.DIGOUT = 0;
    end
else
    if isfield(cfg, 'DIGOUT') && cfg.DIGOUT
        fprintf('xippmex not found on this machine - disabling DIGOUT (running in no-trigger mode).\n');
    end
    cfg.DIGOUT = 0;
end

%% ---------------- Launch task ----------------
fprintf('Launching task\n');
task_function = fullfile(pwd, cfg.TASK_FUNCTION);
if ~isfile(task_function)
    error('%s not found in current folder: %s', cfg.TASK_FUNCTION, pwd);
end
fInfo = dir(task_function);
if fInfo.bytes == 0
    error('%s is empty (0 bytes). Save the task_reading.m code and re-run.', task_function);
end
func_name   = strrep(cfg.TASK_FUNCTION, '.m', '');
resolved_fn = which(func_name);
if ~strcmpi(resolved_fn, task_function)
    warning('Path shadow detected: "%s" resolves to "%s" instead of "%s".', ...
        func_name, resolved_fn, task_function);
end

copyfile(task_function, [cfg.PATH_SRC_TASK filesep cfg.BASE_NAME 'script.m']);
feval(func_name, cfg);

close all;
end
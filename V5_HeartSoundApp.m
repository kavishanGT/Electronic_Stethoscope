classdef V5_HeartSoundApp < matlab.apps.AppBase
    % HeartSoundApp: Real-time heart sound waveform visualizer for ESP32 UDP stream

    properties (Access = public)
        UIFigure             matlab.ui.Figure
        GridLayout           matlab.ui.container.GridLayout
        ControlPanel         matlab.ui.container.Panel
        StartButton          matlab.ui.control.Button
        StopButton           matlab.ui.control.Button
        NotchCheckBox        matlab.ui.control.CheckBox
        NotchFreqDropDown    matlab.ui.control.DropDown
        SampleRateLabel      matlab.ui.control.Label
        SampleRateEditField  matlab.ui.control.NumericEditField
        AmplifierLabel       matlab.ui.control.Label
        AmplifierSlider      matlab.ui.control.Slider
        AmplifierEditField   matlab.ui.control.NumericEditField
        SaveButton           matlab.ui.control.Button
        StatusLabel          matlab.ui.control.Label
        WaveAxes             matlab.ui.control.UIAxes
    end

    properties (Access = private)
        udpObj
        udpPort = 4210
        Fs = 8000
        packetSamples = 256                     % ESP32 PACKET SIZE
        bufferSeconds = 90                      % 1.5 minutes
        plotWindowSeconds = 3                   % show only last 3 seconds on graph
        dataBuffer
        timerObj
        bpFilt
        bNotch
        aNotch
        useNotch = false
        notchFreq = 50
        amplifier = 150                         % amplification factor
        lineHandle
        envBuffer
        envLineHandle
        heartRate = NaN
    end

    methods (Access = private)

        function setupFilters(app)
            % Bandpass filter for heart sounds (20–200 Hz)
            app.bpFilt = designfilt('bandpassiir', ...
                'FilterOrder', 6, ...
                'HalfPowerFrequency1', 40, ...
                'HalfPowerFrequency2', 150, ...
                'SampleRate', app.Fs);

            % Notch filter for 50/60 Hz hum
            wo = app.notchFreq / (app.Fs/2);
            bw = wo / 35;
            [b, a] = iirnotch(wo, bw);
            app.bNotch = b; 
            app.aNotch = a;
        end

        function initBuffer(app)
            bufferLen = app.Fs * app.bufferSeconds;
            app.dataBuffer = zeros(1, bufferLen);
            app.envBuffer = zeros(1, bufferLen);

        end

        function openUDP(app)
            try
                %localIP = "192.168.201.195";   % <-- YOUR WINDOWS IP
                app.udpObj = udpport( ...
                    "datagram", ...
                    "IPV4", ...
                    "LocalPort", app.udpPort);
        
                app.StatusLabel.Text = sprintf("Listening on UDP %d", app.udpPort);
            catch ME
                app.StatusLabel.Text = "UDP Error: " + ME.message;
            end
        end


        function closeUDP(app)
            if ~isempty(app.udpObj)
                try
                    delete(app.udpObj);   % correct
                catch
                end
                app.udpObj = [];
            end
        end


        function timerCallback(app,~,~)

            if isempty(app.udpObj) || ~isvalid(app.udpObj)
                return
            end

            nPackets = app.udpObj.NumDatagramsAvailable;
            %app.StatusLabel.Text = sprintf("UDP packets: %d", nPackets);

            if ~isnan(app.heartRate)
                app.StatusLabel.Text = sprintf("UDP: %d | HR: %.1f bpm", ...
                    nPackets, app.heartRate);
            else
                app.StatusLabel.Text = sprintf("UDP packets: %d", nPackets);
            end

        
            if nPackets == 0
                return
            end            

            while app.udpObj.NumDatagramsAvailable > 0
                try
                    d = read(app.udpObj,1,"uint8");
                catch
                    return
                end

                % Convert bytes -> uint16 samples
                if mod(numel(d.Data), 2) ~= 0
                    continue
                end
        
                raw = typecast(uint8(d.Data), 'uint16');
                raw = double(raw(:))';
                raw = raw - mean(raw);   % <-- ADD THIS

                %raw = double(d.Data(:))';

                % filters
                try
                    filtered = filtfilt(app.bpFilt, raw);
                catch
                    filtered = filter(app.bpFilt, raw);
                end

                if app.useNotch
                    try
                        filtered = filtfilt(app.bNotch, app.aNotch, filtered);
                    catch
                        filtered = filter(app.bNotch, app.aNotch, filtered);
                    end
                end

                % Apply amplification
                filtered = filtered * (app.amplifier / 100);
                env = abs(hilbert(filtered));


                % circular buffer insert
                L = length(filtered);
                BL = length(app.dataBuffer);

                if L >= BL
                    app.dataBuffer = filtered(end-BL+1:end);
                    app.envBuffer = env(end-BL+1:end);
                else
                    app.dataBuffer = [app.dataBuffer(L+1:end), filtered];
                    app.envBuffer = [app.envBuffer(L+1:end), env];
                end
            end

            % ===== HEART RATE ESTIMATION (from envelope buffer) =====
            hrWindowSec = 5;                                % analyze last 5 seconds
            Nhr = round(hrWindowSec * app.Fs);
            
            if length(app.envBuffer) >= Nhr
                envHR = app.envBuffer(end-Nhr+1:end);
            
                try
                    [~, locs] = findpeaks(envHR, ...
                        'MinPeakDistance', round(0.4 * app.Fs), ... % 150 bpm max
                        'MinPeakHeight', 0.3 * max(envHR));
            
                    if numel(locs) >= 2
                        rr = diff(locs) / app.Fs;
                        app.heartRate = 60 / mean(rr);
                    end
                catch
                    % silently ignore rare peak errors
                end
            end



            % update waveform
            app.updatePlot();
        end

        function updatePlot(app)

            % Adjust Y-axis scale inversely to amplification
            baseY = 10000;
            fixedY = [-baseY baseY] * (100 / app.amplifier);

            % Show only last N seconds on graph (controlled by plotWindowSeconds)
            showSamples = round(app.plotWindowSeconds * app.Fs);

            if length(app.dataBuffer) > showSamples
                yPlot = app.dataBuffer(end-showSamples+1:end);
            else
                yPlot = app.dataBuffer;
            end

            

            % Create time axis starting from 0
            tPlot = (0:length(yPlot)-1)/app.Fs;

            if isempty(app.lineHandle) || ~isvalid(app.lineHandle)
                app.lineHandle = plot(app.WaveAxes, tPlot, yPlot, 'LineWidth', 0.8);
                app.WaveAxes.XLim = [0 app.plotWindowSeconds];
                app.WaveAxes.YLim = fixedY;

                xlabel(app.WaveAxes, 'Time (s)');
                ylabel(app.WaveAxes, 'Amplitude');
                title(app.WaveAxes, 'Filtered Heart Sound Waveform');
                grid(app.WaveAxes, 'on');
            else
                set(app.lineHandle, 'XData', tPlot, 'YData', yPlot);
                app.WaveAxes.XLim = [0 app.plotWindowSeconds];
                app.WaveAxes.YLim = fixedY;
            end

            hold(app.WaveAxes, 'on'); 
            if isempty(app.envLineHandle) || ~isvalid(app.envLineHandle)
                app.envLineHandle = plot(app.WaveAxes, tPlot,...
                    app.envBuffer(end-showSamples+1:end),...
                    "r", 'LineWidth',1.2);
            else
                set(app.envLineHandle, 'XData', tPlot,...
                    'YData', app.envBuffer(end-showSamples+1:end));
            end

            hold(app.WaveAxes, 'off');

            drawnow limitrate;
        end
    end

    methods (Access = public)

        function app = V5_HeartSoundApp
            createComponents(app);

            app.Fs = app.SampleRateEditField.Value;
            app.amplifier = app.AmplifierEditField.Value;
            setupFilters(app);
            initBuffer(app);

            app.timerObj = timer('ExecutionMode','fixedSpacing','Period',0.05, ...
                'BusyMode','drop', ... 
                'TimerFcn', @(~,~) app.timerCallback);

            movegui(app.UIFigure,'center')
        end

        function delete(app)
            try
                stop(app.timerObj);
                delete(app.timerObj);
            catch
            end
            closeUDP(app);
            delete(app.UIFigure);
        end
    end

    



    methods (Access = private)

   

        function StartButtonPushed(app,~)
            % Prevent double-start
            if strcmp(app.timerObj.Running, 'on')
                app.StatusLabel.Text = "Already streaming...";
                return
            end
            app.SampleRateEditField.Enable = 'off';
            app.Fs = app.SampleRateEditField.Value;

            setupFilters(app);
            %initBuffer(app);
            closeUDP(app);
            openUDP(app);

            start(app.timerObj);
            app.StatusLabel.Text = "Streaming...";
        end

        function StopButtonPushed(app,~)
            try
                stop(app.timerObj);
            catch
            end
            closeUDP(app);
            app.SampleRateEditField.Enable = 'on';
            app.StatusLabel.Text = "Stopped.";
        end

        function NotchCheckBoxValueChanged(app,~)
            app.useNotch = app.NotchCheckBox.Value;
            app.notchFreq = str2double(app.NotchFreqDropDown.Value);
            setupFilters(app);
        end

        function SampleRateEditFieldValueChanged(app,~)
            app.Fs = app.SampleRateEditField.Value;
            setupFilters(app);
            initBuffer(app);
        end

        function AmplifierValueChanged(app, event)
            if isa(event.Source, 'matlab.ui.control.Slider')
                app.amplifier = round(event.Value);
                app.AmplifierEditField.Value = app.amplifier;
            else
                app.amplifier = event.Value;
                app.AmplifierSlider.Value = app.amplifier;
            end
        end

        function SaveButtonPushed(app,~)
            y = fliplr(app.dataBuffer);  % Reverse to get initial sound first
            if max(abs(y)) > 0
                % Normalize for WAV
                yNorm = (y - min(y)) / (max(y) - min(y));
                filenameWAV = sprintf('HeartSound_%s.wav', datestr(now,'yyyymmdd_HHMMSS'));
                audiowrite(filenameWAV, yNorm, app.Fs);

                % Also save waveform figure
                figure('Visible','off'); % create invisible figure
                t = (0:length(y)-1)/app.Fs;
                plot(t, y);
                xlabel('Time (s)');
                ylabel('Amplitude');
                title('Recorded Heart Sound');
                grid on;
                filenameFig = sprintf('HeartSound_%s.png', datestr(now,'yyyymmdd_HHMMSS'));
                saveas(gcf, filenameFig); % save as PNG
                close(gcf);

                app.StatusLabel.Text = ['Saved WAV: ' filenameWAV ', Graph: ' filenameFig];
            else
                app.StatusLabel.Text = 'Buffer empty — nothing saved.';
            end
        end

        function createComponents(app)
            app.UIFigure = uifigure('Name','Heart Sound Visualizer','Position',[100 100 900 430]);
            app.GridLayout = uigridlayout(app.UIFigure,[1 2]);
            app.GridLayout.ColumnWidth = {'2x','1x'};

            % Plot Panel
            p = uipanel(app.GridLayout);
            p.Layout.Row = 1; p.Layout.Column = 1;
            app.WaveAxes = uiaxes(p);
            app.WaveAxes.Position = [20 20 620 380];
            app.WaveAxes.YLim = [-8000 8000];

            % Control Panel
            C = uipanel(app.GridLayout,'Title','Controls');
            C.Layout.Row = 1; C.Layout.Column = 2;

            g = uigridlayout(C,[11 1]);
            g.RowHeight = repmat({'fit'},1,11);

            app.StartButton = uibutton(g,'push','Text','Start', ...
                'ButtonPushedFcn',@(btn,event)StartButtonPushed(app));
            app.StopButton = uibutton(g,'push','Text','Stop', ...
                'ButtonPushedFcn',@(btn,event)StopButtonPushed(app));

            app.NotchCheckBox = uicheckbox(g,'Text','Enable Notch Filter',...
                'ValueChangedFcn',@(cb,event)NotchCheckBoxValueChanged(app));
            app.NotchFreqDropDown = uidropdown(g,'Items',{'50','60'},'Value','50');

            app.SampleRateLabel = uilabel(g,'Text','Sample Rate (Hz)');
            app.SampleRateEditField = uieditfield(g,'numeric','Value',8000,...
                'ValueChangedFcn',@(ed,event)SampleRateEditFieldValueChanged(app));

            app.AmplifierLabel = uilabel(g,'Text','Amplifier (100-1000)');
            app.AmplifierSlider = uislider(g,'Limits',[100 1000],'Value',100,...
                'ValueChangedFcn',@(sld,event)AmplifierValueChanged(app,event));
            app.AmplifierEditField = uieditfield(g,'numeric','Value',100,...
                'Limits',[100 1000],...
                'ValueChangedFcn',@(ed,event)AmplifierValueChanged(app,event));

            app.SaveButton = uibutton(g,'push','Text','Save WAV', ...
                'ButtonPushedFcn',@(btn,event)SaveButtonPushed(app));

            app.StatusLabel = uilabel(g,'Text','Ready');
        end
    end
end

require "import"
import "com.androlua.Http"
import "cjson"
import "com.androlua.LuaDialog"
import "android.widget.*"
import "android.view.*"
import "android.content.Context"
import "android.content.Intent"
import "android.net.Uri"
import "android.media.MediaPlayer"
import "android.util.Base64"
import "android.os.*"
import "android.graphics.Typeface"
import "java.io.*"
import "android.speech.tts.TextToSpeech"
import "android.app.*"
import "android.content.*"

local context = activity or service
local mainHandler = Handler(Looper.getMainLooper())
local tts = nil
local mainDialog = nil

local CURRENT_VERSION = "1.0"
local VERSION_URL = "https://raw.githubusercontent.com/TechForVI/Google-Gemini-Text-to-Speech/main/version.txt"
local UPDATE_CODE_URL = "https://raw.githubusercontent.com/TechForVI/Google-Gemini-Text-to-Speech/main/maim.lua"
local PLUGIN_PATH = "/storage/emulated/0/解说/Plugins/Google Gemini TTS/main.lua"
local updateInProgress = false
local prefs = context.getSharedPreferences("GeminiTTS_Prefs", Context.MODE_PRIVATE)

pcall(function()
    Http.setConnTimeout(60000)
    Http.setReadTimeout(60000)
end)

local VOICE_LIST = {
    "Puck", "Kore", "Charon", "Zephyr", "Fenrir", "Leda",
    "Orus", "Aoede", "Callirrhoe", "Autonoe", "Enceladus", "Iapetus",
    "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi",
    "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima"
}

local TTS_MODELS = {
    "gemini-3.1-flash-tts-preview",
    "gemini-2.5-flash-preview-tts",
    "gemini-2.0-flash-exp"
}
local CHUNK_SIZE = 1500

local selectedVoice = "Puck"
local selectedModel = TTS_MODELS[1]
local userText = ""
local userFileName = ""
local generatedAudioPath = nil
local mediaPlayer = nil
local isPlaying = false
local googleApiKey = ""
local hasGenerated = false

local activeHttpRequest = nil
local retryCount = 0
local MAX_RETRY = 3

local PREFS_NAME = "Gemini_TTS_Pro"

function trim(s)
    if s == nil then return "" end
    return tostring(s):gsub("^%s*(.-)%s*$", "%1")
end

function showUpdateErrorDialog(title, message)
    mainHandler.post(Runnable({
        run = function()
            local errorDialog = LuaDialog(context)
            errorDialog.setTitle(title)
            errorDialog.setMessage(message)
            errorDialog.setButton("OK", function()
                errorDialog.dismiss()
            end)
            errorDialog.show()
        end
    }))
end

function checkUpdate()
    if updateInProgress then
        showUpdateErrorDialog("Update In Progress", "An update is already in progress. Please wait.")
        return
    end
    
    local timestamp = tostring(os.time())
    Http.get(VERSION_URL .. "?t=" .. timestamp, function(code, response)
        if code == 200 and response then
            local onlineVersion = trim(response)
            if onlineVersion ~= CURRENT_VERSION then
                Http.get(UPDATE_CODE_URL .. "?t=" .. timestamp, function(code2, mainCode)
                    if code2 == 200 and mainCode and trim(mainCode) ~= "" then
                        mainHandler.post(Runnable({
                            run = function()
                                local updateAlertDlg = LuaDialog(context)
                                updateAlertDlg.setTitle("Update Available!")
                                updateAlertDlg.setMessage("A new version (" .. onlineVersion .. ") is available.\nCurrent version: " .. CURRENT_VERSION .. "\n\nWould you like to update now?")
                                updateAlertDlg.setButton("Update Now", function()
                                    updateAlertDlg.dismiss()
                                    performUpdate(mainCode, onlineVersion)
                                end)
                                updateAlertDlg.setButton2("Later", function()
                                    updateAlertDlg.dismiss()
                                end)
                                updateAlertDlg.show()
                            end
                        }))
                    end
                end)
            end
        end
    end)
end

function performUpdate(mainCode, onlineVersion)
    if not mainCode or trim(mainCode) == "" then
        showUpdateErrorDialog("Update Failed", "Main plugin code is empty.")
        return
    end
    
    updateInProgress = true
    
    local function updateProcess()
        local success = false
        local tempPath = PLUGIN_PATH .. ".temp_update"
        local f = io.open(tempPath, "w")
        if f then
            f:write(mainCode)
            f:close()
            
            local fileExists = io.open(PLUGIN_PATH, "r")
            if fileExists then
                fileExists:close()
                local delSuccess = pcall(function()
                    os.remove(PLUGIN_PATH)
                end)
                if delSuccess then
                    local renameSuccess = pcall(function()
                        os.rename(tempPath, PLUGIN_PATH)
                    end)
                    if renameSuccess then
                        success = true
                    end
                end
            else
                local renameSuccess = pcall(function()
                    os.rename(tempPath, PLUGIN_PATH)
                end)
                if renameSuccess then
                    success = true
                end
            end
            
            if not success then
                pcall(function() os.remove(tempPath) end)
            end
        end
        
        if success then
            updateInProgress = false
            mainHandler.post(Runnable({
                run = function()
                    local successDialog = LuaDialog(context)
                    successDialog.setTitle("Update Successful")
                    successDialog.setMessage("Plugin successfully updated to version " .. onlineVersion .. ".\n\nPlugin will restart automatically.")
                    successDialog.setButton("OK", function()
                        successDialog.dismiss()
                        if mainDialog then
                            mainDialog.dismiss()
                        end
                        mainHandler.postDelayed(Runnable({
                            run = function()
                                local pluginFile = io.open(PLUGIN_PATH, "r")
                                if pluginFile then
                                    pluginFile:close()
                                    local func, err = loadfile(PLUGIN_PATH)
                                    if func then
                                        pcall(func)
                                    else
                                        showToast("Error reloading plugin: " .. tostring(err))
                                    end
                                end
                            end
                        }), 2000)
                    end)
                    successDialog.show()
                end
            }))
            return
        else
            updateInProgress = false
            showUpdateErrorDialog("Update Failed", "Update failed. Please try again.")
        end
    end
    
    local updateThread = Thread(luajava.bindClass("java.lang.Runnable"){
        run = updateProcess
    })
    updateThread.start()
end

function initTTS()
    if tts == nil then
        tts = TextToSpeech(context, TextToSpeech.OnInitListener({
            onInit = function(status)
                if status == TextToSpeech.SUCCESS then
                    pcall(function()
                        tts.setLanguage(java.util.Locale.US)
                    end)
                end
            end
        }))
    end
end

function speakFeedback(message)
    initTTS()
    pcall(function()
        if tts then
            tts.speak(message, TextToSpeech.QUEUE_FLUSH, nil)
        end
    end)
end

function runOnUi(callback)
    mainHandler.post(Runnable({ run = callback }))
end

function delay(ms, callback)
    local handler = Handler(Looper.getMainLooper())
    handler.postDelayed(Runnable({ run = callback }), ms)
end

function showToast(msg)
    runOnUi(function()
        Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
    end)
end

function vibrate()
    local vibrator = context.getSystemService(Context.VIBRATOR_SERVICE)
    if vibrator then pcall(function() vibrator.vibrate(35) end) end
end

function saveSettings()
    local editor = prefs.edit()
    editor.putString("voice", selectedVoice)
    editor.putString("model", selectedModel)
    editor.putString("apikey", googleApiKey)
    editor.putString("filename", userFileName)
    editor.apply()
end

function loadSettings()
    selectedVoice = prefs.getString("voice", "Puck")
    selectedModel = prefs.getString("model", TTS_MODELS[1])
    googleApiKey = prefs.getString("apikey", "")
    userFileName = prefs.getString("filename", "")
end

function initMediaPlayer()
    if mediaPlayer ~= nil then
        if isPlaying then
            pcall(function() mediaPlayer.stop() end)
            isPlaying = false
        end
        pcall(function() mediaPlayer.release() end)
    end
    mediaPlayer = MediaPlayer()
end

function togglePlayPause(playBtn)
    if mediaPlayer == nil then
        showToast("No audio loaded")
        return false
    end
    
    if isPlaying then
        pcall(function() mediaPlayer.pause() end)
        isPlaying = false
        runOnUi(function() playBtn.setText("PLAY") end)
    else
        pcall(function() 
            mediaPlayer.start() 
            isPlaying = true
            runOnUi(function() playBtn.setText("PAUSE") end)
        end)
    end
    return true
end

function stopAudio(playBtn)
    if mediaPlayer ~= nil and isPlaying then
        pcall(function() 
            mediaPlayer.stop()
            isPlaying = false
            runOnUi(function() 
                if playBtn then playBtn.setText("PLAY") end
                pcall(function() mediaPlayer.prepare() end)
            end)
        end)
    end
end

function deleteOldAudioFile()
    if generatedAudioPath then
        pcall(function()
            local oldFile = File(generatedAudioPath)
            if oldFile.exists() then
                oldFile.delete()
            end
        end)
        generatedAudioPath = nil
    end
end

function writeWavHeader(outStream, totalAudioLen)
    local sampleRate = 24000
    local channels = 1
    local bitsPerSample = 16
    local byteRate = sampleRate * channels * (bitsPerSample / 8)
    local blockAlign = channels * (bitsPerSample / 8)
    
    local totalDataLen = totalAudioLen
    local totalSize = totalDataLen + 36
    
    local function getBytes(val)
        return {
            val & 0xff,
            (val >> 8) & 0xff,
            (val >> 16) & 0xff,
            (val >> 24) & 0xff
        }
    end
    
    local totalSizeB = getBytes(totalSize)
    local sampleRateB = getBytes(sampleRate)
    local byteRateB = getBytes(byteRate)
    local dataLenB = getBytes(totalDataLen)
    
    local header = {
        0x52, 0x49, 0x46, 0x46,
        totalSizeB[1], totalSizeB[2], totalSizeB[3], totalSizeB[4],
        0x57, 0x41, 0x56, 0x45,
        0x66, 0x6d, 0x74, 0x20,
        0x10, 0x00, 0x00, 0x00,
        0x01, 0x00,
        channels & 0xff, (channels >> 8) & 0xff,
        sampleRateB[1], sampleRateB[2], sampleRateB[3], sampleRateB[4],
        byteRateB[1], byteRateB[2], byteRateB[3], byteRateB[4],
        blockAlign & 0xff, (blockAlign >> 8) & 0xff,
        bitsPerSample & 0xff, (bitsPerSample >> 8) & 0xff,
        0x64, 0x61, 0x74, 0x61,
        dataLenB[1], dataLenB[2], dataLenB[3], dataLenB[4]
    }
    
    for i = 1, #header do
        outStream.write(header[i])
    end
end

function splitTextIntoChunks(text)
    local chunks = {}
    local len = #text
    for i = 1, len, CHUNK_SIZE do
        local chunk = text:sub(i, math.min(i + CHUNK_SIZE - 1, len))
        table.insert(chunks, chunk)
    end
    return chunks
end

function generateSimpleAudio(text, voice, apikey, model, generateBtn, playBtn, resultLayout)
    if activeHttpRequest ~= nil then
        pcall(function()
            if activeHttpRequest.cancel then
                activeHttpRequest.cancel()
            end
        end)
        activeHttpRequest = nil
    end
    
    retryCount = 0
    
    local apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent?key=" .. apikey
    
    local requestBody = {
        contents = {
            {
                parts = {
                    { text = text }
                }
            }
        },
        generationConfig = {
            responseModalities = {"AUDIO"},
            speechConfig = {
                voiceConfig = {
                    prebuiltVoiceConfig = { voiceName = voice }
                }
            }
        }
    }
    
    local headers = HashMap()
    headers.put("Content-Type", "application/json")
    
    local function makeRequest()
        activeHttpRequest = Http.post(apiUrl, cjson.encode(requestBody), headers, function(code, content)
            activeHttpRequest = nil
            
            if code == 200 then
                local ok, data = pcall(cjson.decode, content)
                if ok and data then
                    local base64Audio = nil
                    
                    if data.candidates and #data.candidates > 0 then
                        local candidate = data.candidates[1]
                        if candidate.finishReason and candidate.finishReason ~= "STOP" then
                            runOnUi(function()
                                generateBtn.setEnabled(true)
                                generateBtn.setText("GENERATE")
                                showToast("Model error: " .. candidate.finishReason)
                            end)
                            return
                        end
                        if candidate.content and candidate.content.parts then
                            for i = 1, #candidate.content.parts do
                                local part = candidate.content.parts[i]
                                if part.inlineData and part.inlineData.data then
                                    base64Audio = part.inlineData.data
                                    break
                                end
                            end
                        end
                    end
                    
                    if not base64Audio then
                        local errorMsg = nil
                        if data.candidates and data.candidates[1] and data.candidates[1].content and data.candidates[1].content.parts then
                            for i = 1, #data.candidates[1].content.parts do
                                if data.candidates[1].content.parts[i].text then
                                    errorMsg = data.candidates[1].content.parts[i].text
                                    break
                                end
                            end
                        end
                        if errorMsg then
                            runOnUi(function()
                                generateBtn.setEnabled(true)
                                generateBtn.setText("GENERATE")
                                showToast("API Error: " .. errorMsg:sub(1, 100))
                            end)
                        else
                            local preview = content:sub(1, 150)
                            runOnUi(function()
                                generateBtn.setEnabled(true)
                                generateBtn.setText("GENERATE")
                                showToast("Parse failed: " .. preview)
                            end)
                        end
                        return
                    end
                    
                    local audioBytes = Base64.decode(base64Audio, Base64.NO_WRAP)
                    local tempPath = context.getCacheDir().getPath() .. "/tts_" .. os.time() .. ".wav"
                    local file = File(tempPath)
                    local fos = FileOutputStream(file)
                    writeWavHeader(fos, #audioBytes)
                    fos.write(audioBytes)
                    fos.close()
                    generatedAudioPath = tempPath
                    
                    runOnUi(function()
                        resultLayout.setVisibility(View.VISIBLE)
                        initMediaPlayer()
                        mediaPlayer.setDataSource(generatedAudioPath)
                        mediaPlayer.prepare()
                        playBtn.setEnabled(true)
                        generateBtn.setEnabled(true)
                        generateBtn.setText("REGENERATE")
                        showToast("Audio generated successfully!")
                    end)
                    return
                else
                    runOnUi(function()
                        generateBtn.setEnabled(true)
                        generateBtn.setText("GENERATE")
                        showToast("Invalid JSON response")
                    end)
                end
            elseif code == 429 then
                retryCount = retryCount + 1
                if retryCount <= MAX_RETRY then
                    local waitTime = 5 * (2^(retryCount-1))
                    showToast("Rate limit! Retry " .. retryCount .. "/" .. MAX_RETRY .. " in " .. waitTime .. "s...")
                    delay(waitTime * 1000, function()
                        makeRequest()
                    end)
                else
                    runOnUi(function()
                        generateBtn.setEnabled(true)
                        generateBtn.setText("GENERATE")
                        showToast("Rate limit exceeded after " .. MAX_RETRY .. " retries. Wait a few minutes.")
                    end)
                end
            elseif code == 403 then
                runOnUi(function()
                    generateBtn.setEnabled(true)
                    generateBtn.setText("GENERATE")
                    showToast("Invalid API key. Check API settings.")
                end)
            else
                runOnUi(function()
                    generateBtn.setEnabled(true)
                    generateBtn.setText("GENERATE")
                    showToast("HTTP Error: " .. code)
                end)
            end
        end)
    end
    
    makeRequest()
end

function generateLongAudio(text, voice, apikey, model, generateBtn, playBtn, resultLayout)
    if activeHttpRequest ~= nil then
        pcall(function()
            if activeHttpRequest.cancel then
                activeHttpRequest.cancel()
            end
        end)
        activeHttpRequest = nil
    end
    
    local chunks = splitTextIntoChunks(text)
    local totalChunks = #chunks
    local allAudioData = {}
    local completedChunks = 0
    local hasError = false
    
    local function processChunk(index)
        if hasError then
            runOnUi(function()
                generateBtn.setEnabled(true)
                generateBtn.setText("GENERATE")
            end)
            return
        end
        
        if index > totalChunks then
            if #allAudioData == 0 then
                runOnUi(function()
                    generateBtn.setEnabled(true)
                    generateBtn.setText("GENERATE")
                    showToast("No audio data generated")
                end)
                return
            end
            
            local totalLen = 0
            for i = 1, #allAudioData do
                totalLen = totalLen + #allAudioData[i]
            end
            
            deleteOldAudioFile()
            local tempPath = context.getCacheDir().getPath() .. "/tts_" .. os.time() .. ".wav"
            local file = File(tempPath)
            local fos = FileOutputStream(file)
            writeWavHeader(fos, totalLen)
            
            for i = 1, #allAudioData do
                fos.write(allAudioData[i])
            end
            
            fos.close()
            generatedAudioPath = tempPath
            
            runOnUi(function()
                resultLayout.setVisibility(View.VISIBLE)
                initMediaPlayer()
                mediaPlayer.setDataSource(generatedAudioPath)
                mediaPlayer.prepare()
                playBtn.setEnabled(true)
                generateBtn.setEnabled(true)
                generateBtn.setText("REGENERATE")
                showToast("Audio generated from " .. totalChunks .. " parts!")
            end)
            return
        end
        
        local apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent?key=" .. apikey
        local requestBody = {
            contents = {
                {
                    parts = {
                        { text = chunks[index] }
                    }
                }
            },
            generationConfig = {
                responseModalities = {"AUDIO"},
                speechConfig = {
                    voiceConfig = {
                        prebuiltVoiceConfig = { voiceName = voice }
                    }
                }
            }
        }
        local headers = HashMap()
        headers.put("Content-Type", "application/json")
        
        activeHttpRequest = Http.post(apiUrl, cjson.encode(requestBody), headers, function(code, content)
            activeHttpRequest = nil
            
            if code == 200 then
                local ok, data = pcall(cjson.decode, content)
                if ok and data then
                    local base64Audio = nil
                    
                    if data.candidates and #data.candidates > 0 then
                        local candidate = data.candidates[1]
                        if candidate.finishReason and candidate.finishReason ~= "STOP" then
                            hasError = true
                            runOnUi(function()
                                generateBtn.setEnabled(true)
                                generateBtn.setText("GENERATE")
                                showToast("Chunk " .. index .. " failed: " .. candidate.finishReason)
                            end)
                            return
                        end
                        if candidate.content and candidate.content.parts then
                            for i = 1, #candidate.content.parts do
                                local part = candidate.content.parts[i]
                                if part.inlineData and part.inlineData.data then
                                    base64Audio = part.inlineData.data
                                    break
                                end
                            end
                        end
                    end
                    
                    if base64Audio then
                        table.insert(allAudioData, Base64.decode(base64Audio, Base64.NO_WRAP))
                        completedChunks = completedChunks + 1
                        runOnUi(function()
                            showToast("Part " .. index .. "/" .. totalChunks .. " completed")
                        end)
                        delay(1500, function()
                            processChunk(index + 1)
                        end)
                    else
                        local errorMsg = nil
                        if data.candidates and data.candidates[1] and data.candidates[1].content and data.candidates[1].content.parts then
                            for i = 1, #data.candidates[1].content.parts do
                                if data.candidates[1].content.parts[i].text then
                                    errorMsg = data.candidates[1].content.parts[i].text
                                    break
                                end
                            end
                        end
                        if errorMsg then
                            hasError = true
                            runOnUi(function()
                                generateBtn.setEnabled(true)
                                generateBtn.setText("GENERATE")
                                showToast("API Error chunk " .. index .. ": " .. errorMsg:sub(1, 100))
                            end)
                        else
                            hasError = true
                            local preview = content:sub(1, 150)
                            runOnUi(function()
                                generateBtn.setEnabled(true)
                                generateBtn.setText("GENERATE")
                                showToast("Parse failed chunk " .. index .. ": " .. preview)
                            end)
                        end
                    end
                else
                    hasError = true
                    runOnUi(function()
                        generateBtn.setEnabled(true)
                        generateBtn.setText("GENERATE")
                        showToast("JSON decode error chunk " .. index)
                    end)
                end
            elseif code == 429 then
                showToast("Rate limit! Waiting 8 seconds...")
                delay(8000, function()
                    processChunk(index)
                end)
            else
                hasError = true
                runOnUi(function()
                    generateBtn.setEnabled(true)
                    generateBtn.setText("GENERATE")
                    showToast("HTTP Error: " .. code .. " chunk " .. index)
                end)
            end
        end)
    end
    
    processChunk(1)
end

function downloadAudioToInternalStorage()
    if not generatedAudioPath then
        showToast("Generate audio first")
        speakFeedback("No audio file to download")
        return false
    end
    
    local sourceFile = File(generatedAudioPath)
    if not sourceFile.exists() then
        showToast("Audio file not found")
        return false
    end
    
    local fileName = (userFileName ~= "" and userFileName or "voice_" .. os.time()) .. ".wav"
    local downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
    
    if not downloadDir.exists() then
        downloadDir.mkdirs()
    end
    
    local destFile = File(downloadDir, fileName)
    local success = false
    
    pcall(function()
        local input = FileInputStream(sourceFile)
        local output = FileOutputStream(destFile)
        local buffer = byte[8192]
        local len
        while true do
            len = input.read(buffer)
            if len == -1 then break end
            output.write(buffer, 0, len)
        end
        output.close()
        input.close()
        success = true
    end)
    
    if success then
        showToast("Saved to: " .. destFile.getAbsolutePath())
        speakFeedback("Download successful")
        local intent = Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE)
        intent.setData(Uri.fromFile(destFile))
        context.sendBroadcast(intent)
        return true
    else
        showToast("Download failed")
        return false
    end
end

function showApiSettings()
    local views = {}
    
    local layout = {
        LinearLayout,
        orientation = "vertical",
        padding = "24dp",
        layout_width = "fill",
        layout_height = "wrap",
        {
            TextView,
            text = "API CONFIGURATION",
            textSize = 18,
            textColor = "#2196F3",
            gravity = "center",
            paddingBottom = "20dp",
            typeface = Typeface.DEFAULT_BOLD
        },
        {
            TextView,
            text = "Google API Key:",
            textSize = 14,
            textColor = "#333333",
            paddingBottom = "8dp"
        },
        {
            EditText,
            id = "apiInput",
            hint = "Enter your Google Gemini API key",
            layout_width = "fill",
            layout_height = "wrap",
            backgroundColor = "#F5F5F5",
            padding = "12dp"
        },
        {
            TextView,
            text = "Get API key from: console.cloud.google.com",
            textSize = 11,
            textColor = "#2196F3",
            paddingTop = "8dp",
            paddingBottom = "16dp"
        },
        {
            LinearLayout,
            orientation = "horizontal",
            layout_width = "fill",
            layout_height = "wrap",
            layout_marginTop = "10dp",
            {
                Button,
                id = "testBtn",
                text = "TEST",
                layout_width = "0dp",
                layout_weight = "1",
                backgroundColor = "#FF9800",
                textColor = "#FFFFFF",
                padding = "12dp",
                layout_marginRight = "5dp"
            },
            {
                Button,
                id = "saveBtn",
                text = "SAVE",
                layout_width = "0dp",
                layout_weight = "1",
                backgroundColor = "#4CAF50",
                textColor = "#FFFFFF",
                padding = "12dp",
                layout_marginLeft = "5dp"
            },
            {
                Button,
                id = "closeBtn",
                text = "CLOSE",
                layout_width = "0dp",
                layout_weight = "1",
                backgroundColor = "#9E9E9E",
                textColor = "#FFFFFF",
                padding = "12dp",
                layout_marginLeft = "5dp"
            }
        }
    }
    
    local dlg = LuaDialog(context)
    dlg.setTitle("API Settings")
    dlg.setView(loadlayout(layout, views))
    dlg.setCancelable(true)
    
    views.apiInput.setText(googleApiKey)
    
    views.testBtn.onClick = function()
        local key = views.apiInput.getText().toString()
        if key == "" then
            showToast("Please enter API key first")
            return
        end
        views.testBtn.setText("Testing...")
        views.testBtn.setEnabled(false)
        local testUrl = "https://generativelanguage.googleapis.com/v1beta/models?key=" .. key
        Http.get(testUrl, nil, function(code, content)
            runOnUi(function()
                views.testBtn.setText("TEST")
                views.testBtn.setEnabled(true)
                if code == 200 then
                    showToast("API key is valid!")
                else
                    showToast("Invalid API key. Error: " .. code)
                end
            end)
        end)
    end
    
    views.saveBtn.onClick = function()
        local apikey = views.apiInput.getText().toString()
        if apikey == "" then
            showToast("Please enter API key")
            return
        end
        googleApiKey = apikey
        saveSettings()
        showToast("Settings saved successfully")
        dlg.dismiss()
    end
    
    views.closeBtn.onClick = function()
        dlg.dismiss()
    end
    
    dlg.show()
end

function aboutAndSupport()
    vibrate()
    local help_views = {}
    local help_layout = {
        LinearLayout;
        orientation = "vertical";
        padding = "16dp";
        layout_width = "fill";
        layout_height = "wrap";
        {
            TextView;
            text = "Google Gemini Text to Speech Plugin - Generate high quality WAV audio from text using Google Gemini AI.\n\nFeatures: 24+ natural voices, 1500 character chunk processing, exponential backoff for rate limits, direct download to device, and WAV format output at 24kHz sample rate.\n\nVersion: " .. CURRENT_VERSION .. "\n\nDeveloper: Sabir Jamil";
            textSize = 14;
            textColor = "#666666";
            gravity = "left";
            paddingBottom = "20dp";
        };
        {
            TextView;
            text = "Join Our Community";
            textSize = 16;
            textColor = "#000000";
            gravity = "center";
            paddingBottom = "10dp";
        };
        {
            ScrollView;
            layout_width = "fill";
            layout_height = "wrap_content";
            {
                LinearLayout;
                orientation = "vertical";
                layout_width = "fill";
                layout_height = "wrap_content";
                gravity = "center";
                layout_marginTop = "5dp";
                {
                    Button;
                    id = "joinWhatsAppGroupButton";
                    text = "JOIN WHATSAPP GROUP";
                    layout_width = "fill";
                    layout_height = "wrap_content";
                    layout_margin = "2dp";
                    textSize = "12sp";
                    padding = "8dp";
                    backgroundColor = "#25D366";
                    textColor = "#FFFFFF";
                };
                {
                    Button;
                    id = "joinYouTubeChannelButton";
                    text = "JOIN YOUTUBE CHANNEL";
                    layout_width = "fill";
                    layout_height = "wrap_content";
                    layout_margin = "2dp";
                    textSize = "12sp";
                    padding = "8dp";
                    backgroundColor = "#FF0000";
                    textColor = "#FFFFFF";
                };
                {
                    Button;
                    id = "joinTelegramChannelButton";
                    text = "JOIN TELEGRAM CHANNEL";
                    layout_width = "fill";
                    layout_height = "wrap_content";
                    layout_margin = "2dp";
                    textSize = "12sp";
                    padding = "8dp";
                    backgroundColor = "#2196F3";
                    textColor = "#FFFFFF";
                };
                {
                    Button;
                    id = "goBackButton";
                    text = "GO BACK";
                    layout_width = "fill";
                    layout_height = "wrap_content";
                    layout_margin = "2dp";
                    textSize = "12sp";
                    padding = "8dp";
                    backgroundColor = "#9E9E9E";
                    textColor = "#FFFFFF";
                };
            };
        };
    }
    local help_dialog = LuaDialog(context)
    help_dialog.setTitle("Developer: Sabir Jamil")
    help_dialog.setView(loadlayout(help_layout, help_views))
    help_dialog.setCancelable(true)
    
    help_views.joinWhatsAppGroupButton.onClick = function()
        if mainDialog then
            mainDialog.dismiss()
        end
        help_dialog.dismiss()
        local success, errorMsg = pcall(function()
            local message = "Assalam%20o%20Alaikum.%20I%20hope%20you%20are%20doing%20well.%20I%20would%20like%20to%20join%20your%20WhatsApp%20group.%20Kindly%20share%20the%20instructions.%20group%20rules%20and%20regulations.%20Thank%20you.%20so%20much"
            local url = "https://wa.me/923486623399?text=" .. message
            local intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            context.startActivity(intent)
        end)
        if not success then
            showToast("Could not open WhatsApp")
        end
    end
    
    help_views.joinYouTubeChannelButton.onClick = function()
        if mainDialog then
            mainDialog.dismiss()
        end
        help_dialog.dismiss()
        local success, errorMsg = pcall(function()
            local url = "https://www.youtube.com/@TechForVI"
            local intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            context.startActivity(intent)
        end)
        if not success then
            showToast("Could not open YouTube")
        end
    end
    
    help_views.joinTelegramChannelButton.onClick = function()
        if mainDialog then
            mainDialog.dismiss()
        end
        help_dialog.dismiss()
        local success, errorMsg = pcall(function()
            local url = "https://t.me/TechForVI"
            local intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            intent.setPackage("org.telegram.messenger")
            context.startActivity(intent)
        end)
        if not success then
            pcall(function()
                local url = "https://t.me/TechForVI"
                local intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                context.startActivity(intent)
            end)
        end
    end
    
    help_views.goBackButton.onClick = function()
        help_dialog.dismiss()
    end
    
    help_dialog.setOnCancelListener{
        onCancel = function()
            help_dialog.dismiss()
        end
    }
    help_dialog.show()
end

function showMain()
    loadSettings()
    initMediaPlayer()
    initTTS()
    hasGenerated = false
    
    local views = {}
    
    local scrollLayout = {
        ScrollView,
        layout_width = "fill",
        layout_height = "fill",
        {
            LinearLayout,
            orientation = "vertical",
            padding = "30dp",
            layout_width = "fill",
            layout_height = "wrap",
            {
                TextView,
                text = "Google Gemini Text to Speech",
                textSize = 20,
                textColor = "#2E7D32",
                gravity = "center",
                paddingBottom = "8dp",
                typeface = Typeface.DEFAULT_BOLD            },
            {
                TextView,
                text = "Developer: Sabir Jamil  |  v" .. CURRENT_VERSION,
                textSize = 12,
                textColor = "#666666",
                gravity = "center",
                paddingBottom = "25dp"
            },
            {
                EditText,
                id = "textInput",
                hint = "Type your text here...",
                layout_width = "fill",
                layout_height = "150dp",
                backgroundColor = "#F5F5F5",
                padding = "15dp",
                gravity = Gravity.TOP,
                textSize = 14,
                layout_marginBottom = "15dp"
            },
            {
                TextView,
                text = "Voice Selection:",
                textSize = 14,
                textColor = "#333333",
                paddingBottom = "5dp"
            },
            {
                Spinner,
                id = "voiceSpin",
                layout_width = "fill",
                layout_height = "wrap",
                backgroundColor = "#F5F5F5",
                layout_marginBottom = "15dp"
            },
            {
                TextView,
                text = "Model Selection:",
                textSize = 14,
                textColor = "#333333",
                paddingBottom = "5dp"
            },
            {
                Spinner,
                id = "modelSpin",
                layout_width = "fill",
                layout_height = "wrap",
                backgroundColor = "#F5F5F5",
                layout_marginBottom = "15dp"
            },
            {
                EditText,
                id = "fileNameInput",
                hint = "File name (without extension)",
                layout_width = "fill",
                layout_height = "wrap",
                backgroundColor = "#F5F5F5",
                padding = "12dp",
                layout_marginBottom = "15dp"
            },
            {
                Button,
                id = "generateBtn",
                text = "GENERATE",
                layout_width = "fill",
                layout_height = "wrap",
                backgroundColor = "#2196F3",
                textColor = "#FFFFFF",
                padding = "16dp",
                textSize = 16,
                layout_marginBottom = "15dp"
            },
            {
                LinearLayout,
                id = "resultLayout",
                orientation = "horizontal",
                layout_width = "fill",
                layout_height = "wrap",
                visibility = View.GONE,
                layout_marginBottom = "15dp",
                {
                    Button,
                    id = "playBtn",
                    text = "PLAY",
                    layout_width = "0dp",
                    layout_weight = "1",
                    backgroundColor = "#4CAF50",
                    textColor = "#FFFFFF",
                    padding = "12dp",
                    layout_marginRight = "5dp",
                    enabled = false
                },
                {
                    Button,
                    id = "downloadBtn",
                    text = "DOWNLOAD",
                    layout_width = "0dp",
                    layout_weight = "1",
                    backgroundColor = "#FF9800",
                    textColor = "#FFFFFF",
                    padding = "12dp",
                    layout_marginLeft = "5dp"
                }
            },
            {
                LinearLayout,
                orientation = "horizontal",
                layout_width = "fill",
                layout_height = "wrap",
                {
                    Button,
                    id = "apiBtn",
                    text = "API Setting",
                    layout_width = "0dp",
                    layout_weight = "1",
                    backgroundColor = "#9C27B0",
                    textColor = "#FFFFFF",
                    padding = "12dp",
                    layout_marginRight = "5dp"
                },
                {
                    Button,
                    id = "aboutBtn",
                    text = "ABOUT & SUPPORT",
                    layout_width = "0dp",
                    layout_weight = "1",
                    backgroundColor = "#607D8B",
                    textColor = "#FFFFFF",
                    padding = "12dp",
                    layout_marginLeft = "5dp",
                    layout_marginRight = "5dp"
                },
                {
                    Button,
                    id = "exitBtn",
                    text = "EXIT",
                    layout_width = "0dp",
                    layout_weight = "1",
                    backgroundColor = "#D32F2F",
                    textColor = "#FFFFFF",
                    padding = "12dp",
                    layout_marginLeft = "5dp"
                }
            }
        }
    }
    
    local dlg = LuaDialog(context)
    dlg.setTitle("Google Gemini TTS")
    dlg.setCancelable(false)
    dlg.setView(loadlayout(scrollLayout, views))
    mainDialog = dlg
    
    views.textInput.setText("")
    views.fileNameInput.setText(userFileName)
    
    views.textInput.addTextChangedListener({
        afterTextChanged = function(editable)
            userText = editable.toString()
        end
    })
    
    views.fileNameInput.addTextChangedListener({
        afterTextChanged = function(editable)
            userFileName = editable.toString()
            saveSettings()
        end
    })
    
    local voiceAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, VOICE_LIST)
    voiceAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
    views.voiceSpin.setAdapter(voiceAdapter)
    
    for i, v in ipairs(VOICE_LIST) do
        if v == selectedVoice then
            views.voiceSpin.setSelection(i - 1)
            break
        end
    end
    
    views.voiceSpin.onItemSelectedListener = {
        onItemSelected = function(p, v, pos)
            selectedVoice = VOICE_LIST[pos + 1]
            saveSettings()
        end
    }
    
    local modelAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, TTS_MODELS)
    modelAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
    views.modelSpin.setAdapter(modelAdapter)
    
    for i, m in ipairs(TTS_MODELS) do
        if m == selectedModel then
            views.modelSpin.setSelection(i - 1)
            break
        end
    end
    
    views.modelSpin.onItemSelectedListener = {
        onItemSelected = function(p, v, pos)
            selectedModel = TTS_MODELS[pos + 1]
            saveSettings()
        end
    }
    
    views.playBtn.onClick = function()
        if not generatedAudioPath then
            showToast("Generate audio first")
            return
        end
        if mediaPlayer == nil then
            initMediaPlayer()
            pcall(function()
                mediaPlayer.setDataSource(generatedAudioPath)
                mediaPlayer.prepare()
            end)
        end
        togglePlayPause(views.playBtn)
    end
    
    views.downloadBtn.onClick = function()
        vibrate()
        downloadAudioToInternalStorage()
    end
    
    views.generateBtn.onClick = function()
        local currentText = views.textInput.getText().toString()
        if currentText == "" then
            showToast("Please enter text first!")
            vibrate()
            return
        end
        
        if googleApiKey == "" then
            showToast("Please configure API key in API Setting!")
            showApiSettings()
            return
        end
        
        userText = currentText
        
        if mediaPlayer ~= nil then
            if isPlaying then
                pcall(function() mediaPlayer.stop() end)
                isPlaying = false
            end
            pcall(function() mediaPlayer.release() end)
            mediaPlayer = nil
        end
        
        deleteOldAudioFile()
        
        views.playBtn.setEnabled(false)
        views.playBtn.setText("PLAY")
        views.resultLayout.setVisibility(View.GONE)
        isPlaying = false
        hasGenerated = false
        
        views.generateBtn.setEnabled(false)
        views.generateBtn.setText("GENERATING...")
        views.generateBtn.setBackgroundColor(0xFF9E9E9E)
        
        local textLength = #userText
        
        if textLength <= CHUNK_SIZE then
            generateSimpleAudio(userText, selectedVoice, googleApiKey, selectedModel, views.generateBtn, views.playBtn, views.resultLayout)
        else
            generateLongAudio(userText, selectedVoice, googleApiKey, selectedModel, views.generateBtn, views.playBtn, views.resultLayout)
        end
    end
    
    views.apiBtn.onClick = function()
        showApiSettings()
        vibrate()
    end
    
    views.aboutBtn.onClick = function()
        aboutAndSupport()
    end
    
    views.exitBtn.onClick = function()
        if activeHttpRequest ~= nil then
            pcall(function()
                if activeHttpRequest.cancel then
                    activeHttpRequest.cancel()
                end
            end)
            activeHttpRequest = nil
        end
        if mediaPlayer ~= nil then
            pcall(function() mediaPlayer.release() end)
            mediaPlayer = nil
        end
        deleteOldAudioFile()
        if tts then
            pcall(function() tts.stop() end)
            pcall(function() tts.shutdown() end)
        end
        dlg.dismiss()
    end
    
    dlg.show()
end

Thread(luajava.bindClass("java.lang.Runnable"){
    run = function()
        Thread.sleep(3000)
        checkUpdate()
    end
}).start()

loadSettings()
if googleApiKey == "" then
    showToast("Please configure your API key first")
    showApiSettings()
else
    showMain()
end
#!/usr/bin/env coffee
# CoffeeSync by Eiríkur Hallgrímsson (C) 2010, 2011, 2012
# released under the terms of the GNU General Public License V2

# FIXME:
# --verify might do something useful.
# --debug might....

# We use these NodeJS standard library routines.  Note that we are assuming Node 0.30 or later.
{spawn, exec}  = require 'child_process'
{print, puts, debug, error, inspect, p, log, pump, inherits} = require 'util'
fs = require 'fs'
events = require 'events'

starts_with = (data, target) ->
    return (data.substring(0, target.length) == target)

notify = (text) ->
    exec "notify-send CoffeeSync '#{text}'"


rsync = (source, dest, dryrun, delete_files, existing ) ->
    options =  "--perms --executability --update --xattrs --owner --group --cvs-exclude --times"
    options += " --archive --human-readable --partial --recursive --timeout=300 --one-file-system"
    options += " --out-format='%n'"
    options += " --delete-during --force" if delete_files # Okay to delete non-empty dirs on destination.
    options += " --existing" if existing # Do not create new files on destination
    # Exclude iso images which are not worth backing up and information.org which is confidential
    # *.vmdk is a virtual disk image file for VMware, *.vdi for VirtualBox
    excludes = " --exclude='*.iso'  --exclude='information.org' --exclude='*.vmdk' --exclude='*.vdi' --exclude='Trash'"
    excludes += " --exclude='.thumbnails' --exclude='.cache' --exclude='cache' --exclude='Cache'" # Add more home directory excludes over time.
    excludes += " --exclude='.ssh' --exclude='*.tar'" # Never copy or overwrite ssh keys. Don't copy tarchives.
    excludes += " --exclude='local'" # Avoid copying nodejs binaries.
    excludes += " --exclude='Downloads'" # Avoid copying downloads.
    dryrun = if dryrun then "--dry-run" else "--stats" # Either dry-run or get stats
    # New version of nodeJS has some problem if we 'exec' rsync instead of just running it.
    #    cmd = "exec rsync #{source} #{dryrun} #{dest} #{options} #{excludes}"
    cmd = "rsync #{source} #{dest} #{dryrun} #{options} #{excludes}"
    return exec cmd

# Displays a Zenity text message window, which we use to display errors.
class ErrorListDialog extends events.EventEmitter
    constructor: (@title) ->
        @dialog = exec "zenity --width=600 --text-info --title='#{@title}'\n"
        @dialog.on 'exit', (status) -> @emit 'dismissed'
    write: (buffer) ->
        @dialog.stdin.write buffer


class Syncer extends events.EventEmitter
    # src, dest, dry-run, okay-to-delete, file_list
    constructor: (@source, @destination) ->
        @deleting = 'deleting '
        @results = []
    scan: (@delete, @existing)->
        @dryrun = true
        notify "Only EXISTING files will be updated." if @existing
        notify "Files missing on source will be DELETED!" if @delete
        @show_scan_progress() # Create throbbing progress dialog
        @do_rsync(@source, @destination, @dryrun, @delete, @existing)
    execute: (@delete, @existing)->
        @dryrun = false
        notify "Only EXISTING files will be updated." if @existing
        notify "Files missing on source will be DELETED!" if @delete
        @show_execute_progress(@results.length) # There has been a scan phase and @results is populated.
        @do_rsync(@source, @destination, @dryrun, @delete, @existing)
    do_rsync: (@source, @destination, @dryrun, @delete, @existing) ->
        @rsync = rsync(@source, @destination, @dryrun, @delete, @existing)
        @rsync.stdout.on 'data', (buffer) => @process_output buffer # For each chunk of output from rsync
        @rsync.stderr.on 'data', (buffer) => @error buffer  # For each error message
        # @rsync.on 'exit', (status, signal) => @done status, signal # This could miss the statistics message.
        @rsync.stdout.on 'close', (status, signal) => @done status, signal
        @rsync.stdout.on 'disconnect', (status, signal) => @error 'disconnect received in do_rsync'

    show_scan_progress: ->
        @progress_dialog = new ScanProgress(@source, @destination)
        @progress_dialog.on 'cancelled', => @cancel() # When canceled from the dialog, call our cancel method.
        @progress_dialog.on 'exit', (status, signal) => @progress_dialog_exited(status, signal) # When the dialog exits...
    show_execute_progress: ->
        @progress_dialog = new ExecuteProgress(@source, @destination, @results.length)
        @progress_dialog.on 'cancelled', => @cancel() # When canceled from the dialog, call our cancel method.
        @progress_dialog.on 'exit', (status, signal) => @progress_dialog_exited(status, signal) # When the dialog exits...
    process_output: (buffer) ->
        for line in buffer.toString().split("\n")
            line = line.trim()
            if line.length > 0
                console.log line
                @handle_warnings line
                @capture_deletes line
                # if line.indexOf('%')  > -1 #@handle_file_progress line
                #     @handle_file_progress line
                # else
                @results.push line
                @progress_dialog.write "\##{line}"
    # handle_file_progress: (line) ->
    #     line = line.replace /\s+/g, ' '
    #     # console.log "progress: #{line}"
    #     tokens = (line.trim().split ' ').length
    #     console.log "tokens: #{tokens}"
    #     if false # tokens > 6 # we have a problem, Houston FIXME
    #         console.log line
    #         for c in line
    #             console.log c.charCodeAt 0
    #     # return true
    handle_warnings: (line) ->
        warning = "Warning:"
        if starts_with(line, warning)
            notify line
            puts "Warning detected!"
            puts line
    error: (msg) ->
        notify "Error reported by Syncer.error: #{msg}"
        puts   "Error reported by Syncer.error: #{msg}"
        @errors = [] unless @errors? # Create holder variable unless it already exists
        @errors.push msg # 24 April 2012 found this omission when reading the code.
        @error_dialog = new ErrorListDialog "CoffeeSync: Errors during Copy" unless @error_dialog? # Create window if needed.        @errors.push msg
        @error_dialog.on 'dismissed', -> @error_dialog_dismissed()
        @error_dialog.write msg
    error_dialog_dismissed: (value) => # Status is 0 for okay, 1 for not okay.
        if value then process.exit(125) else @exit()
    cancel: () ->
        @rsync.kill('SIGKILL')
        process.exit(125) # Linux ECANCELED
    capture_deletes: (line) ->
        @deletes = [] unless @deletes? # Create this instance variable unless it exists.
        @deletes.push line if (line.substring(0, @deleting.length) == @deleting) # save it if it begins thusly
    progress_dialog_exited: (status, signal) ->
        # This is the primary exit pathway.
        @exit()
    done: (status, signal) => # If there are errors, exiting is done by dismissing the error_dialog.
        # puts "debug: #{status} #{signal}"
        console.log "DONE DONE DONE DONE DONE DONE DONE DONE DONE DONE DONE DONE DONE DONE DONE DONE DONE DONE"
        @progress_dialog.close() if @progress_dialog? # Close the zenity dialog if it still exists, triggering exit.
    statistics: ->
        statistics = @results[@results.length-13..@results.length-1] # The statistics msg from rsync.
        # puts @results.join '\n'
        return statistics.join '\n'
    show_deletes: ->
        @text_window = new DisplayText @deletes
        title = "CoffeeSync: Files exist on destination that have been removed from source."
        text = "Remove these files from destination?"
        @dialog = new QuestionDialog(title, text)
        @dialog.on 'yes',  ->
            @text_window.close()
            @deletes = []
            @emit 'okay_to_delete'
        @dialog.on 'no',  ->
            @text_window.close()
            @deletes = []
            @emit 'do_not_delete'
    exit: =>
        return @show_deletes() if deletes.length if deletes?
        if @errors? # If there is a list of errors...
            @emit 'errors'
        else
            if @dryrun
                @emit 'scan_complete'
            else
                stats = @statistics()
                @emit 'finished', stats


class Progress extends events.EventEmitter
    # Displays a Zenity progress bar that throbs to show activity.
    # We put up this window while rsync is scanning to find what
    # needs to be updated. next_function is called when the dialog is dismissed.
    constructor: (@title='title', @text='text', @count=0) ->
        @writable = true
        @display()
    display: ->
        @cmd = "zenity --width=650 --progress --auto-close --auto-kill --title='#{@title}' --text='#{@text}'"
        @cmd += " --pulsate" if not @count # No count means scan phase.
        @dialog = exec @cmd
        @dialog.on 'exit', (status, signal) =>
            @emit 'cancelled' if signal is 'SIGHUP'
            @emit 'done' if signal is 'SIGTERM' or signal is 'SIGKILL' # Killed by the rsync process so that we don't have to wait.
            if status is 0 or status is null then @emit 'exit', 0, signal else @zenity_error status, signal
        @dialog.stdin.on 'drain', => @drain()
    drain: ->
        @writable = true
    throttled_write: (data) => # If we get a false returned, do not write until a drain event.
        try # 24 April 2012: added 'and' check of the writable property to avoid writing to a closed socket.
            # Was getting "Error: This socket is closed."
            @writable = @dialog.stdin.write "#{data}\n" if @writable and @dialog.stdin.writable
        catch e
            @error_dialog = new ErrorListDialog "CoffeeSync: Error updating Progress Bar" unless @error_dialog? # Create window if needed.
            @error_dialog.on 'dismissed', -> @error_dialog_dismissed()
            @error_dialog.write e
            puts "Error in throttled_write: #{e}"
    error_dialog_dismissed: (value) => # Status is 0 for okay, 1 for not okay.
        if value then process.exit(125) else @exit()
    update_progress_bar: (value) =>
        @dialog.stdin.write "#{value}\n" if @dialog.stdin.writable
    close: ->
        @dialog.stdin.write "100\n" if @dialog.stdin.writable # Close the zenity dialog using the --auto-close at 100%
    zenity_error: (status, signal) -> puts "zenity dialog exited with error status: #{status} and signal: #{signal}"

class ScanProgress extends Progress
    constructor: (@source, @destination)->
        @title  =  "CoffeeSync is scanning #{@source} and #{@destination} ..."
        @text   =  "Initial read of #{@source} and #{@destination}"
        super @title, @text
    write: (data) ->
        @throttled_write(data)


class ExecuteProgress extends Progress
    constructor: (@source, @destination, @file_count) ->
        @counter = 0
        @percent = .01 * @file_count
        @percent_counter = 0
        @title  =  "CoffeeSync is syncing #{@file_count} files from #{@source} to #{@destination}"
        @text   =  "Preparing...."
        super @title, @text, @file_count
    write: (data) ->
        @throttled_write(data)
        @counter += 1
        if @counter > @percent # We have processed one percent worth of files.
            @counter = 0
            @percent_counter += 1 # This is our cumulative percentage done.
            @update_progress_bar @percent_counter

# Displays a Zenity informational message window with msg.
class InformationDialog
    constructor: (@title, @msg) ->
        @dialog = "zenity --info --title='#{title}' --text='#{msg}'\n"

# Displays a Zenity error message window with msg.
class ErrorDialog
    constructor: (@title, @msg) ->
        @dialog = "zenity --error --title='#{title}' --text='#{msg}'\n"

class DisplayText extends events.EventEmitter
    constructor: (@text) ->
        now = new Date
        epoch = now.getTime() # Milliseconds
        @filespec = "/tmp/csync-temp-file_#{epoch}"
        @put_to_file(@text, @filespec)
        @show_file(@filespec)
    put_to_file: (data, filespec) ->
        data = stringify data if typeof data is 'object'
        fs.writeFileSync filespec, data, encoding = 'utf8'
    show_file: (filespec) =>
        @window = exec "exec gedit #{filespec}"  # Now we wait for it to appear on the screen.
        setTimeout(@visible, 2000) # After two seconds we should be visible, so emit the signal.
    visible: =>
        @emit 'visible', @window
        exec "rm #{@filespec}"
    stringify: (list) ->
        list_string = ""
        list_string += "#{item}\n" for item in list
        return list_string
    close: ->
        @window.kill 'SIGKILL'

class QuestionDialog extends events.EventEmitter
    constructor: (title, message) ->
        @dialog = exec "zenity --question --title='#{title}' --text='#{message}'  --width=600"
        @dialog.on 'exit', (status) =>
            @answer = if status then 'no' else 'yes'
            @emit @answer

class Report extends events.EventEmitter
    constructor: (source, destination, text)->
        @title = "CoffeeSync of #{source} to #{destination} complete."
        @dialog = exec "zenity --timeout=30 --height=600 --info --title='#{@title}' --text='#{text}'\n"
        @dialog.on 'exit', -> process.exit(0) # This is our normal exit


class Main
    constructor: (@source, @destination, @delete_flag, @existing_flag) ->
        @sync = new Syncer source, destination
        @sync.on 'errors', => @errors()
        @sync.on 'scan_complete', => @execute(@delete_flag, @existing_flag)
        @sync.on 'finished', (@stats) => @report()
        @sync.on 'okay_to_delete', => @execute(true, @existing_flag)
        @sync.on 'do_not_delete', => @execute(false, @existing_flag)
    start: =>
        @sync.scan(@delete_flag, @existing_flag)
    execute: =>
        @sync.execute(@delete_flag, @existing_flag)
    report: =>
        @rpt = new Report(@source, @destination, @stats) # And we exit in the exit handler from this dialog.
        text = "CoffeeSync of #{@source} to #{@destination} is complete."
        exec "notify-send CoffeeSync '#{text}'"
        # notification_icon = exec "zenity --notification --text='#{text}' --window-icon=/usr/share/icons/Humanity/apps/128/gnome-info.svg"
        # notification_icon.on 'exit', -> exec "wmctrl -R CoffeeSync" # Raise results window if notification icon clicked
        # notification_icon.stdout.on 'data', (data) -> puts data
        # notification_icon.stderr.on 'data', (data) -> puts data
    errors: =>
        @error_dialog = new ErrorDialog("CoffeeSync encountered errors", "Please investigate and try again.")

class Command extends events.EventEmitter
    constructor: ->
        @args = []
        @opts = []
        for item in process.argv
            if item[0] isnt '-'
                @args.push item
            else
                @opts.push item
        @emit 'bad arguments', @args  if @args.length != 2
        @source = @args[2]
        @destination = @args[3]
    get_option: (options) ->
        for item in options
            for opt in @opts
                return true if item == opt
        return false

cmd = new Command
cmd.on 'bad arguments', (args)->
    puts "Arguments: #{args} just will not work."
    puts "Exactly two postional arguments are required.  They are the source and destination."
    process.exit(1)

VERIFY = cmd.get_option ['-v', '--verify']
DELETE = cmd.get_option ['-d', '--delete']
EXISTING = cmd.get_option ['-e', '--existing'] # Do not create new files on destination

source = cmd.source
destination = cmd.destination

#################### Main Program starts here. ####################

main = new Main source, destination, DELETE, EXISTING
main.start()

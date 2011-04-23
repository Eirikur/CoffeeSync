#!/usr/bin/env coffee
# CoffeeSync by Eiríkur Hallgrímsson (C) 2010, 2011
# released under the terms of the GNU General Public License V2

# FIXME: --delete not yet supported
# --verify might do something useful.
# --debug might....

# We use these NodeJS standard library routines.  Note that we are assuming Node 0.30 or later.
{spawn, exec}  = require 'child_process'
{print, puts, debug, error, inspect, p, log, pump, inherits} = require 'util'
fs = require 'fs'
events = require 'events'

rsync = (source, dest, dryrun, delete_files ) ->
    options =  "--perms --executability --update --xattrs --owner --group --cvs-exclude --times"
    options += " --archive --human-readable --partial --recursive --timeout=60 --one-file-system"
    options += " --out-format='%n'"
    options += " --delete-during --force" if delete_files # Okay to delete non-empty dirs on destination.
    # Exclude iso images which are not worth backing up and information.org which is confidential
    # *.vmdk is a virtual disk image file for VMware, *.vdi for VirtualBox
    excludes = " --exclude='*.iso'  --exclude='information.org' --exclude='*.vmdk' --exclude='*.vdi' --exclude='Trash'"
    dryrun = if dryrun then "--dry-run" else "--stats" # Either dry-run or get stats
    # New version of nodeJS has some problem if we 'exec' rsync instead of just running it.
    #    cmd = "exec rsync #{source} #{dryrun} #{dest} #{options} #{excludes}"
    cmd = "rsync #{source} #{dest} #{dryrun} #{options} #{excludes}"
    return exec cmd

# Displays a Zenity text message window, which we use to display errors.
class ErrorDialog extends events.EventEmitter
    constructor: (@title) ->
        @dialog = exec "zenity --text-info --title='#{@title}'\n"
        @dialog.on 'exit', (status) -> @emit 'dismissed'
    write: (buffer) ->
        @dialog.stdin.write buffer


class Syncer extends events.EventEmitter
    # src, dest, dry-run, okay-to-delete, file_list
    constructor: (@source, @destination, @dryrun, @delete, @file_list) ->
        @deleting = 'deleting '
        @results = []
        @progress_dialog = new SyncProgress(@source, @destination, @dryrun, @delete, @file_list.length)
        @progress_dialog.on 'cancelled', => @cancel() # When canceled from the dialog, call our cancel method.
        @progress_dialog.on 'exit', (status, signal) => @progress_dialog_exited(status, signal) # When the dialog exits...
        @rsync = rsync(source, destination, @dryrun, @delete)
        @rsync.stdout.on 'data', (buffer) => @process buffer # For each chunk of output from rsync
        @rsync.stderr.on 'data', (buffer) => @error buffer  # For each error message
        @rsync.on 'exit', (status, signal) => @done status, signal
    process: (buffer) ->
        for line in buffer.toString().split("\n")
            line = line.trim()
            if line.length > 0
                @capture_deletes line
                @results.push line
                @progress_dialog.write "\##{line}"
    error: (msg) ->
        puts "rsync error:", msg
        @errors = [] unless @errors? # Create holder variable unless it already exists
        @error_dialog = new ErrorDialog "CoffeeSync: Errors during Copy" unless @error_dialog? # Create window if needed.        @errors.push msg
        @error_dialog.on 'dismissed', -> @error_dialog_dismissed()
        @error_dialog.write msg
    cancel: () ->
        @rsync.kill('SIGKILL')
        process.exit(125) # Linux ECANCELED
    capture_deletes: (line) ->
        @deletes = [] unless @deletes? # Create this instance variable unless it exists.
        @deletes.push line if (line.substring(0, @deleting.length) == @deleting) # save it if it begins thusly
    progress_dialog_exited: (status, signal) ->
        @exit()
    error_dialog_dismissed:  =>
        @emit 'done', @results
    done: (status, signal) => # If there are errors, 'done' is emitted by dismissing the error_dialog.
        @progress_dialog.kill() if @progress_dialog? # Close the zenity dialog.
    exit: =>
        @emit 'done', @results



class SyncProgress extends events.EventEmitter
    # Displays a Zenity progress bar that throbs to show activity.
    # We put up this window while rsync is scanning to find what
    # needs to be updated. next_function is called when the dialog is dismissed.
    constructor: (@source, @destination, @dryrun, @delete, @count = 0) ->
        @counter = 0
        @percent = .01 * count
        @percent_counter = 0
        @shutting_down = false
        if @dryrun
            title  =  "CoffeeSync is scanning #{@source} and #{@destination} ..."
            text   =  "Initial read of #{@source} and #{@destination}"
        else
            title  =  "CoffeeSync is syncing #{@count} files from #{@source} to #{@destination}"
            text   =  "Preparing...."
        cmd = "zenity --width=650 --progress --auto-close --auto-kill --title='#{title}' --text='#{text}'"
        cmd += " --pulsate" if @dryrun
        @dialog = exec cmd
        @dialog.on 'exit', (status, signal) =>
            # puts "zenity exit during scan. status: #{status} signal: #{signal}"
            @emit 'cancelled' if signal is 'SIGHUP'
            @emit 'done' if signal is 'SIGTERM' or signal is 'SIGKILL' # Killed by the rsync process so that we don't have to wait.
            if status is 0 or status is null then @emit 'exit', 0, signal else @zenity_error status, signal
    write: (data) ->
        if not @shutting_down
            if not @dryrun # This is a real copy operation
                @dialog.stdin.write "#{data}\n" if @dialog.stdin.writable
                @counter += 1
                if @counter = @percent # We have processed one percent worth of files.
                    @counter = 0
                    @percent_counter += 1 # This is our cumulative percentage done.
                    @dialog.stdin.write "#{@percent_counter}\n" if @dialog.stdin.writable
            else #Throttle output during scan by showing only directories.
                @dialog.stdin.write "#{data}\n" if data[data.length - 1 ] is '/' if @dialog.stdin.writable
    kill: ->
        @shutting_down = true
        @dialog.stdin.write "100\n" if @dialog.stdin.writable # Close the zenity dialog using the --auto-close at 100%
    zenity_error: (status, signal) -> puts "zenity dialog exited with error status: #{status} and signal: #{signal}"



# Displays a Zenity informational message window with msg.
class InformationDialog
    constructor: (@title, @msg) ->
        @dialog = "zenity --info --title='#{title}' --text='#{msg}'\n"



#################### Main Program starts here. ####################

# No clever command line parsing, sorry. Options must come after the source and destination.
source      = process.argv[2] # This is the directory that will be synced.
destination = process.argv[3] # This is the destination of the sync.

DELETE = if "--delete" in process.argv then true else false
HELP = if "--help" in process.argv then true else false
# TODO FIXME not used yet
VERIFY = if (("-v" in process.argv) or ("--verify" in process.argv)) then true else false


# Do this on successful exit. FIXME just create it and let it propogate
#timestamp('.TIMESTAMP', source, destination) # Create a timestamp on source and copy to destination.
#exec 'killall rsync'

# exec 'rm -rf /tmp/cs2/*'

# source = '/usr/lib'
# destination = '/tmp/cs2/'

start_time = Date.now()
# source, destination, dryrun, delete-flag, file_list.
# file_list only meaningful if dryrun is false.  During the dryrun pass we don't have a list yet.
scanner = new Syncer source, destination, true, DELETE, []
scanner.on 'done', (file_list) ->
    copier = new Syncer source, destination, false, DELETE, file_list
    copier.on 'done', (file_list)->
        notification_icon = exec "zenity --notification --window-icon=/usr/share/icons/Humanity/apps/128/gnome-info.svg"
        notification_icon.on 'exit', -> exec "wmctrl -R CoffeeSync"
        notify_message = "Successful sync of\n#{source}\nto\n#{destination}"
        exec "notify-send CoffeeSync '#{notify_message}'"
        statistics = file_list[file_list.length-13..file_list.length-1] # The statistics msg from rsync.
        text = statistics.join '\n'
        title = "CoffeeSync of #{source} to #{destination} is complete."
        report = exec "zenity --info --width=575 --title='#{title}' --text='#{text}'"
        report.on 'exit', -> process.exit(0)



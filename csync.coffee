#!/usr/bin/env coffee
# CoffeeSync by Eiríkur Hallgrímsson (C) 2010, 2011
# released under the terms of the GNU General Public License V2

# FIXME: stderr error dialog isn't a global var.  Doesn't save state.

# We use these NodeJS standard library routines.  Note that we are assuming Node 0.30 or later.
{spawn, exec}  = require 'child_process'
{print, puts, debug, error, inspect, p, log, pump, inherits} = require 'util'
fs = require 'fs'

# Returns a child process object that is running cmd.
# We can write to its stdin and read from stdout and stderr
do_cmd = (cmd) ->
    return exec cmd

# Create a timestamp file and copy it to the destination.  FIXME: this isn't used yet.
timestamp = (timestamp_file_name, source, dest) ->
    source += '/' if not (source[source.length-1] == '/')
    do_cmd "touch #{source}#{timestamp_file_name}"
    do_cmd "scp #{source}#{timestamp_file_name} #{destination}"

# Performs an rsync of source to dest.  If dryrun is true then just scan and report files needing to be updated.
rsync = (source, dest, dryrun, delete_files ) ->
    options =  "--perms --executability --update --xattrs --owner --group --cvs-exclude --times"
    options += " --archive --human-readable --partial --recursive --timeout=60 --one-file-system"
    options += " --out-format='%n'"
    options += " --delete-during --force" if delete_files # Okay to delete non-empty dirs on destination.
    # Exclude iso images which are not worth backing up and information.org which is confidential
    # *.vmdk is a virtual disk image file for VirtualBox.
    excludes = " --exclude='*.iso'  --exclude='information.org' --exclude='*.vmdk' --exclude='Trash'"
    dryrun = if dryrun then "--dry-run" else "--stats" # Either dry-run or get stats
    # New version of nodeJS has some problem if we 'exec' rsync instead of just running it.
    #    cmd = "exec rsync #{source} #{dryrun} #{dest} #{options} #{excludes}"
    cmd = "rsync #{source} #{dryrun} #{dest} #{options} #{excludes}"
    return do_cmd cmd

# Displays a Zenity progress bar that throbs to show activity.
# We put up this window while rsync is scanning to find what files
# need to be updated. Returns the child process object.
scan = (source, destination) ->
    title  =  "CoffeeSync is scanning #{source} and #{destination}"
    text = "Initial read of #{source} and #{destination}"
    # text = padding + text + padding # The padding makes the progress bar longer/more readable.
    cmd = "zenity --progress --pulsate --auto-close --auto-kill --title='#{title}' --text='#{text}'"
    return do_cmd cmd

# Displays a Zenity progress bar window and returns a child process object.
# Shows the count of files that need updating.
progress = (source, destination, count) ->
    title  =  "CoffeeSync is updating #{count} files."
    text = "Performing backup of #{source} to #{destination}"
    text = padding + text + padding # The padding makes the progress bar longer/more readable.
    cmd = "zenity --progress --title='#{title}' --text='#{text}' --auto-close --auto-kill --percentage=1"
    return do_cmd cmd

# Displays a Zenity informational message window with msg.
info = (title, msg) ->
    return do_cmd "zenity --info --title='#{title}' --text='#{msg}'\n"

# Displays a Zenity text message window, which we use to display errors.
errors = (title) ->
    return do_cmd "zenity --text-info --title='#{title}'\n"

# Displays a Zenity warning window because we are about to delete files.
# This is displayed over a gedit window which contains the list of files.
process_deletes_and_continue = (list) ->
    filespec = "/tmp/csync-files-to-delete.txt"
    list_string = ""
    list_string += "#{item}\n" for item in list
    fs.writeFileSync filespec, list_string, encoding = 'utf8'
    GEDIT = do_cmd "exec gedit #{filespec}"  # Now we wait for it to appear on the screen.
    setTimeout(ask_about_deletes, 2000, GEDIT) # After two seconds call ask_about_deletes

ask_about_deletes = (GEDIT) ->
    title = "CoffeeSync: Files exist on destination that have been removed from source."
    text = "Remove these files from destination?"
    dialog = do_cmd "zenity --question --title='#{title}' --text='#{text}'  --width=600"
    dialog.on 'exit', (status) ->
        do_deletes = not status
        GEDIT.kill 'SIGKILL'
        perform_actions(SCAN_RESULTS, do_deletes)

# The start of a complete logging system.  It's just for debugging issues with files
# that can't be copied right now.
log = (msg) ->
    log_array.push msg
    # puts "Log: #{msg}"

# Detect file deletion messages and put them into DELETE_ARRAY
is_delete = (line) ->
    d = 'deleting '
    if (line.substring(0, d.length) == d)
        line = line.substring(d.length, line.length) # remove prefix
        DELETE_ARRAY.push "#{line}"
        return true
    else
       return false # return status is no longer used.


# Given the scan results, perform the required actions.
perform_actions = (SCAN_RESULTS, do_deletes) ->
    counter = 0
    percent_counter = 0
    lines = SCAN_RESULTS.length # This is the list of files that will be updated.
    percent = lines*.01         # This is the number of lines in one percent of the list.
    progress_bar = progress source, destination, SCAN_RESULTS.length
    progress_bar.on 'exit', (status) ->
        puts "User canceled from progress dialog. Exit status: #{status}"
        rsync_process.stdin.close
        process.exit(status) # Exit this program, propagating the status code.
    rsync_process = rsync(source, destination, false, do_deletes) # src, dst, dryrun, delete flag
    # Handler for messages sent from rsync to stderr.
    rsync_process.stderr.on 'data', (buffer) ->
        print "rsync_process error: #{buffer}\n"
        log buffer
        e = errors("CoffeeSync: Error from rsync during copy") unless e? # Create window if needed.
        msg = "#{buffer}\n"
        e.stdin.write msg
        log msg
    # Handler for progress information on stdout
    rsync_process.stdout.on 'data', (buffer) ->
        glob = buffer.toString().split("\n")
        for line in glob
            if line.length > 1
                results.push line
                log line
                progress_bar.stdin.write "\##{line}\n"
                counter += 1
                if counter > percent
                    counter = 0
                    percent_counter += 1
                    progress_bar.stdin.write "#{percent_counter}\n"

    rsync_process.on 'exit', (status) ->
        end_time = new Date
        elapsed_time = start_time - end_time
        progress_bar.stdin.write "100\n" # Let Zenity dialog know we are done.
        progress_bar.stdin.close # Close the stream.
        statistics = log_array[log_array.length-13..log_array.length-1] # The statistics msg from rsync.
        statistics = statistics.join '\n'
        exit_status = if status then "Exit status: #{status}" else ""
        info "'CoffeeSync of #{source} to #{destination} Complete.'",  statistics
        process.exit status # Report the actual rsync exit status to the shell.


#################### Main Program starts here. ####################

start_time = new Date
SCAN_RESULTS = [] # The list of files that need to be updated.
results = []      # The list of files that have been updated so far.
# Dialog padding.   Tweak to taste.
padding = "                                        "
log_array = []
DELETE_ARRAY = []
GEDIT = ""
# No clever command line parsing, sorry. Options must come after the source and destination.
source      = process.argv[2] # This is the directory that will be synced.
destination = process.argv[3] # This is the destination of the sync.

# Do this on successful exit.
#timestamp('.TIMESTAMP', source, destination) # Create a timestamp on source and copy to destination.

# TODO FIXME not used yet
DELETE = if "--delete" in process.argv then true else false
VERIFY = if (("-v" in process.argv) or ("--verify" in process.argv)) then true else false

# Create the zenity progress bar window for the initial 'scan' rsync --dry-run
scanning = scan source, destination
scanning.stdin.write "1\n" # Start progress bar at one percent

# Create the child process that performs the initial scan. Dryrun = true, delete = true.
scanner = rsync(source, destination, true, true)
scanner.stdout.on 'data', (buffer) ->    # When the child process produces a line of output, do the following.
    glob = buffer.toString().split("\n") # We might get multiple lines at once.
    for line in glob
        if not is_delete line # If this line performs a delete, we don't display it.
            if line.length > 1 # This is a file name.  rsync has determined that it needs to be updated on the destination.
                SCAN_RESULTS.push line
                log line
                scanning.stdin.write "\##{line}\n" # Put the filename into the progress bar window.

# Handler for messages sent from rsync to stderr.
scanner.stderr.on 'data', (buffer) ->
    log buffer
    e = errors("CoffeeSync: Errors from rsync during scan") unless e? # Create window if needed.
    msg = "#{buffer}\n"
    e.stdin.write msg

# When the scanner child process exits the real work begins.
# This is where the real rsync to update the files is started.
scanner.on 'exit', (status) ->
    do_deletes = false
    scanning.stdin.write "100\n" # Close the scanning progress dialog via --auto-close.
    scanning.on 'exit', (status) -> # Zenity can be backlogged and take a while to close.
        if DELETE and DELETE_ARRAY.length # DELETE is the command line option to enable deleting files.
            process_deletes_and_continue(DELETE_ARRAY)
        else
            perform_actions(SCAN_RESULTS, false) # False means don't pass the --delete-during flag to rsync

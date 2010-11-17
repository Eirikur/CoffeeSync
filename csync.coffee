#!/usr/bin/env coffee
# We use these library routines
{spawn, exec}  = require 'child_process'
{print, puts, debug, error, inspect, p, log, pump, inherits} = require 'util'

# Dialog padding.   Tweak to taste.
padding = "                                        "

# Returns a child process object that is running cmd.
# We can write to its stdin and read from stdout and stderr
do_cmd = (cmd) ->
    return exec cmd

# Performs an rsync of source to dest.  If dryrun is true then just scan and report files needing to be updated.
rsync = (source, dest, dryrun ) ->
    dryrun = if dryrun then "--dry-run" else "-v" # Either dry-run or get stats
    cmd = "exec rsync #{source} #{dryrun} --perms --executability --update --xattrs --owner --group --cvs-exclude --archive --human-readable --partial --recursive --timeout=60 --one-file-system --times --exclude='*.iso' --exclude='information.*' --exclude='.subversion' --update --out-format='%n' #{dest}"
    return do_cmd cmd

# Displays a Zenity progress bar window and returns a child process object.
# Shows the count of files that need updating.
progress = (source, destination, count) ->
    title  =  "CoffeeSync is updating #{count} files."
    text = "Performing backup of #{source} to #{destination}"
    text = padding + text + padding # The padding makes the progress bar longer/more readable.
    cmd = "zenity --progress --title='#{title}' --text='#{text}' --auto-close --auto-kill --percentage=1"
    return do_cmd cmd

# Displays a Zenity progress bar that throbs to show activity.
# We put up this window while rsync is scanning to find what files need to be updated.
# Returns the child process object.
scan = (source, destination) ->
    title  =  "CoffeeSync is scanning #{source} and #{destination}"
    text = "Initial read of #{source} and #{destination}"
    text = padding + text + padding # The padding makes the progress bar longer/more readable.
    cmd = "zenity --progress --pulsate --auto-close --auto-kill --title='#{title}' --text='#{text}'"
    return do_cmd cmd

# Displays a Zenity informational message window with msg.
info = (title, msg) ->
    cmd = do_cmd "zenity --info --title='#{title}' --text='#{msg}'\n"

# Displays a Zenity text message window, which we use to display errors.
errors = (title) ->
    cmd = do_cmd "zenity --text-info --title='#{title}'\n"

# Main Program starts here.
start_time = new Date
scan_results = [] # The list of files that need to be updated.
results = []      # The list of files that have been updated so far.

# No clever command line parsing, sorry.
source      = process.argv[0] # This is the directory that will be synced.
destination = process.argv[1] # This is the destination of the sync.

# Create the zenity progress bar window for the initial 'scan' rsync --dry-run
scanning = scan source, destination
scanning.stdin.write "1\n" # Start progress bar at one percent

# Create the child process that performs the initial scan.
scanner = rsync(source, destination, true)
scanner.stdout.on 'data', (buffer) ->    # When the child process produces a line of output, do the following.
    glob = buffer.toString().split("\n") # We might get multiple lines at once.
    for line in glob
        if line.length > 1  # This is a file name.  rsync has determined that it needs to be updated on the destination.
            scan_results.push line
            scanning.stdin.write "\##{line}\n" # Put the filename into the progress bar window.

# Handler for messages sent from rsync to stderr.
scanner.stderr.on 'data', (buffer) ->
    e = errors("CoffeeSync: Error from rsync") unless e? # Create window if needed.
    e.stdin.write buffer

# When the scanner child process exits the real work begins.
# This is where the real rsync to update the files is started.
scanner.on 'exit', (status) ->
    end_time = new Date
    counter = 0
    percent_counter = 0
    glob = []
    lines = scan_results.length # This is the list of files that will be updated.
    percent = lines*.01         # This is the number of lines in one percent of the list.

    scanning.stdin.write "100\n" # Close the scanning progress dialog via --auto-close.
    scanning.stdin.close
    progress_bar = progress source, destination, scan_results.length

    progress_bar.on 'exit', (status) ->
        puts "User canceled from progress dialog."
        rsync_process.stdin.end
        rsync_process.stdin.close
        # rsync_process.kill 'SIGKILL'
        process.exit # Exit this program.

    rsync_process = rsync(source, destination, false)

    # Handler for messages sent from rsync to stderr.
    scanner.stderr.on 'data', (buffer) ->
        e = errors("CoffeeSync: Error from rsync") unless e? # Create window if needed.
        e.stdin.write buffer

    # Handler for progress information on stdout
    rsync_process.stdout.on 'data', (buffer) ->
        glob = buffer.toString().split("\n")
        for line in glob
            if line.length > 1
                results.push line
                progress_bar.stdin.write "\##{line}\n"
                counter += 1
                if counter > percent
                    counter = 0
                    percent_counter += 1
                    progress_bar.stdin.write "#{percent_counter}\n"

    rsync_process.on 'exit', (status) ->
        end_time = new Date
        elapsed_time = start_time - end_time
        print "Elapsed time: #{elapsed_time}"
        progress_bar.stdin.write "100\n" # Let Zenity dialog know we are done.
        progress_bar.stdin.close # Close the stream.
        rsync_statistics = results[results.length-1] # The statistics msg from rsync.
        results_msg ="#{rsync_statistics}\nExit status: #{status}"
        print "#{rsync_statistics}"
        info "'CoffeeSync of #{source} to #{destination} Complete.'",  results_msg
        print "Done. Exiting..."
        process.exit status # Report the actual rsync exit status to the shell.


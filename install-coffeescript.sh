#!/bin/bash
# Script to install node (Node.js), npm (Node Package Manager) and
# Coffeescript by Eirikur Hallgrimsson, November 2010

# Create a directory tree under our home dir.
mkdir --parents ~/local/bin # Create ~/local/bin, creating local if needbe.
mkdir --parents ~/local/share/man
mkdir ~/local/.node_libraries
mkdir ~/local/src

echo "Checking for git..."
if ! which git
    then
        echo "Please install the git version control system and try again."
        exit
    else
        echo "You've got git.  Good!"
fi


# Get Node from the repository, build it, and install it.
cd local/src
git clone https://github.com/ry/node.git
cd node
./configure --prefix=$HOME/local/ # Installation will be under ~/local
make
make install

# Ok, now the node executable is installed in ~/local/bin
# We need to put that in our path.
export PATH=$HOME/local/bin:$PATH # For this session
export PATH=$HOME/local/share/man:$PATH #
echo 'export PATH=~/local/bin:${PATH}' >> ~/.bashrc # For subsequent sessions.
echo 'export PATH=~/local/share/man:${PATH}' >> ~/.bashrc


# We need to set up defaults for npm before installing it.
cat >>~/.npmrc <<NPMRC
root = ~/local/.node_libraries
binroot = ~/local/bin
manroot = ~/local/share/man
NPMRC

# Get npm (Node package manager), built it and install it.
cd ~/local/src
git clone https://github.com/isaacs/npm.git
cd npm
make install

# Now we can use npm to install CoffeeScript.  Yes, npm knows it as 'coffee-script.'
npm install coffee-script
which coffee
coffee -e 'puts "Greetings printed by CoffeeScript!"'
echo "See http://nodul.es/ for an index of other tools and libraries for Node."
echo "Any of those can be imported and used by CoffeeScript."



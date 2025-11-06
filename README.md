You must first create the webserver and its contents.  
This is very simple and entirely automated.

---

## 1. Pull the repository and create the environment

Open a terminal and run the following commands:

```bash
mkdir sandbox            # create a folder to hold pulled files
cd ./sandbox

git init
git pull https://github.com/NickCarreiro/CYBR428-ICA.git

chmod +x *.sh            # allow all bash scripts to be executed

sudo ./create.sh         # installs necessary dependencies for the exercise
                         # this should take ~2–3 minutes
```

Once those commands complete, the environment is ready.

---

## 2. Start the simulated webserver

In the same (or a new) terminal run:

```bash
cd ./sandbox             # if not already in your sandbox

sudo ./run.sh            # initializes the simulated web-server; wait for it to finish
```

Then scan the host to discover open services:

```bash
nmap -sV -T4 0.0.0.0
```

Note the port the webserver is running on (we’ll call it `<port>` below).

---

## 3. Enumerate with Gobuster

Run Gobuster to find hidden pages and directories:

```bash
sudo gobuster dir -w ./ica_wordlist.txt -u http://0.0.0.0:<port>
```

Replace `<port>` with the actual port number you found from `nmap`.

---

## 4. Find flags

Visit each hit returned by Gobuster and look for flags.  
Flags use the format:

```
FLAG{flagDetailsHere}
```

Find at least **two** flags.

---

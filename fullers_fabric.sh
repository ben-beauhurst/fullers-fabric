#!/bin/bash

# Fuller's Fabric - a pure Bash replacement for Fabric.

# TODO - keyword arguments in options
# TODO - print docstrings (with args) when listing commands
# TODO - make options comma-separated rather than space-separated, as in Fabric

ENVIRONMENT=""
while IFS= read -r line; do
    # Check if line matches the pattern
    if [[ "$line" =~ ^ukf_environment=(.*)$ ]]; then
        # Extract the value using bash regex capture group
        ENVIRONMENT="${BASH_REMATCH[1]}"
        break  # Found ukf_environment!
    fi
done < ~/.fabricrc
if [[ ! $ENVIRONMENT ]]; then
  echo "No ukf_environment! Please set ukf_environment in your ~/.fabricrc file."
  exit 1
fi

declare -A environ_mapping
environ_mapping[live]="-live"
environ_mapping[staging]="-live -staging"
environ_mapping[entitymatching]="-entitymatching"
environ_mapping[local]=""

declare -A operating_systems
operating_systems[Linux]="linux"
operating_systems[Darwin]="mac"
OPERATING_SYSTEM=${operating_systems[$(uname -s)]}

RED="\033[31m"
BOLD_GREEN="\033[1;32m"
YELLOW="\033[33m"
BOLD_YELLOW="\033[1;33m"
RESET="\033[0m"

AWS_REGION="eu-west-2"


##########################
# Declare command groups #
# ########################

declare -A commands
commands[manage]="django_admin django_shell migrate makemigrations collectstatic"
commands[testing]="run_tests"
commands[deploy]="redeploy build up down npm_run build_static compile_static"
commands[helpers]="lint format_python lint_python mypy"


#####################
# Command functions #
#####################

# manage

django_admin() {
  command="$1"
  read_only=$(cast_to_bool "$2")
  docker_compose "run --rm -e DJANGO_READ_ONLY=${read_only} web_shell django-admin ${command}"
}

django_shell() {
  print_sql=""
  if [[ $(cast_to_bool "$1") == "1" ]]; then
    print_sql="--print-sql"
  fi
  read_only=$(cast_to_bool "$2")
  django_admin "shell_plus --quiet-load ${print_sql}" $read_only
}

migrate() {
  app="$1"
  target_migration="$2"
  database=""
  if [[ $3 ]]; then
    database="--database=$3"
  fi
  settings=""
  if [[ $4 ]]; then
    settings="--settings=$4"
  fi
  docker_compose "run --rm web_shell django-admin migrate ${app} ${target_migration} ${database} ${settings}"
}

makemigrations() {
  appname="$1"
  migration_name=""
  if [[ $appname && $2 ]]; then
    migration_name="--name $2"
  fi
  docker_compose "run --rm web_shell django-admin makemigrations ${appname} ${migration_name}"
}

collectstatic() {
  options="$1"
  django_admin "collectstatic --verbosity=2 --no-input --ignore ukfgeneral/js/vue-components/** --ignore ukfgeneral/scss/** ${options}"
}

# testing

run_tests() {
  # TODO - lots of options here to add
  path="$1"
  default_n_processes=2
  n_processes=""
  if [[ $2 == "auto" ]]; then
    n_processes="--numprocesses=$(nproc)"
  elif [[ $path ]]; then
    n_processes=--numprocesses=1
  elif [[ $2 =~ ^[0-9]+$ ]]; then
    n_processes="--numprocesses=$2"
  else
    n_processes="--numprocesses=$default_n_processes"
  fi

  docker_compose "run --rm web_shell pytest apps/${path} ${n_processes}"
}

# deploy

redeploy() {
  build "false"
  printf " && "
  up
  printf " && "
  migrate
  printf " && "
  compile_static
}

up() {
  if [[ OPERATING_SYSTEM == "mac" ]]; then
    printf "docker-sync start && "
  fi
  docker_compose "up --detach --remove-orphans"
}

build() {
  restart=1
  if [[ $1 ]]; then
    restart=$(cast_to_bool "$1")
  fi
  printf "mkdir -p ../data && "
  printf "git rev-parse HEAD > docker_built_from_git_id && "
  printf "git describe --all > docker_built_from_git_branch && "
  aws_account_id=$(aws sts get-caller-identity --query Account --output text)
  ecr_url="${aws_account_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  printf "aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ecr_url} && "
  docker_compose "build"
  if [[ $restart == "1" ]]; then
    printf " && "
    up
  fi
}

down() {
  docker_compose "down"
  if [[ OPERATING_SYSTEM == "mac" ]]; then
    printf " && docker-sync stop"
  fi
}

npm_run() {
  command="$1"
  docker_compose "run --rm frontend npm run ${command}"
}

build_static() {
  npm_run "dev-build"
}

compile_static() {
  clear_static_directory=0
  if [[ $1 ]]; then
    clear_static_directory=$(cast_to_bool "$1")
  fi
  if [[ $clear_static_directory == "1" ]]; then
    printf "sudo rm -rdf ../media/ukf/managed/* && "
  fi
  build_static
  printf " && "
  collectstatic
}


# helpers

format_python() {
  path="."
  if [[ $1 ]]; then
    path="$1"
  fi
  docker_compose "run --rm web_shell ruff format ${path}"
}

lint_python() {
  path="."
  if [[ $1 ]]; then
    path="$1"
  fi
  docker_compose "run --rm web_shell ruff check --fix --unsafe-fixes ${path}"
}

mypy() {
  path="."
  if [[ $1 ]]; then
    path="$1"
  fi
  docker_compose "run --rm web_shell mypy ${path} --cache-dir=/root/shared/.mypy_cache"
}

lint() {
  printf "echo \"${BOLD_GREEN}format_python${RESET}\" && "
  format_python
  printf " && echo \"${BOLD_GREEN}lint_python${RESET}\" && "
  lint_python
  printf " && echo \"${BOLD_GREEN}validate_templates${RESET}\" && "
  django_admin "validate_templates"
  printf "&& echo \"${BOLD_GREEN}mypy${RESET}\" && "
  mypy
}


####################
# Helper functions #
####################

lower() {
    # Usage: lower "string"
    printf '%s\n' "${1,,}"
}

cast_to_bool() {
  input=$(lower "$1")
  case "$input" in
    t|true|1|y|yes) echo "1" ;;
    f|false|0|n|no) echo "0" ;;
    *) echo "0" ;;
  esac
}

docker_compose() {
  printf "docker compose "
  read -ra suffixes <<< "${environ_mapping[$ENVIRONMENT]}"
  for suffix in "${suffixes[@]}"; do
    printf -- "-f docker-compose${suffix}.yml "
  done
  if [[ $ENVIRONMENT == "local" ]]; then
    printf -- "-f docker-compose.yml -f docker-compose-${OPERATING_SYSTEM}.yml "
  fi
  printf -- "$@"
}

list_commands() {
  if [[ $1 && ! -v commands[$1] ]]; then
    echo "Command group \"$1\" is unknown!"
    return 1
  fi
  echo "COMMANDS ($OPERATING_SYSTEM, $ENVIRONMENT):"
  echo ""
  for group in "${!commands[@]}"; do
    if [[ ! $1 || $1 == $group ]]; then
      echo "  ${group}:"
      read -ra subcommands <<< "${commands[$group]}"
      for subcommand in "${subcommands[@]}"; do
        echo "    - ${group}.${subcommand}"
      done
    fi
  done
}

run() {
  subcommand="$1"
  options="$2"
  command=$(eval "$subcommand $options")
  echo "Running command: \"$command\""
  eval "$command"
}


########
# Main #
########

if [[ ! $1 ]]; then
  echo -e "${YELLOW}                                                       .--    ..${RESET}"
  echo -e "${YELLOW}                                               - -    .---  ..--${RESET}"
  echo -e "${YELLOW}                                             -.--+   -.---..+-+${RESET}"
  echo -e "${YELLOW}                                         --..--+++ --....----++${RESET}"
  echo -e "${YELLOW}                                         +++++-#++--...----+++     -+${RESET}"
  echo -e "${YELLOW}                                          -+-.-+---...-----+#++++++#++${RESET}"
  echo -e "${YELLOW}                                         -..---+---..---+++##+-+  --${RESET}"
  echo -e "${YELLOW}                                        -.-.---+---.---+-##    #-+${RESET}"
  echo -e "${YELLOW}                                        ---.---....---+-+-----  +-+${RESET}"
  echo -e "${YELLOW}                                        ----.---..++-..---..-+---++${RESET}"
  echo -e "${YELLOW}                                       --++++--..-++++++----.+++-${RESET}"
  echo -e "${YELLOW}                                   +-.--++#++++-.+########+-.--${RESET}"
  echo -e "${YELLOW}                                  ++..-+++   -++++   #+.-+++--+++${RESET}"
  echo -e "${YELLOW}                                  ++-..-++    -+#+    ---###+++-+#${RESET}"
  echo -e "${BOLD_YELLOW}                     E S T D${RESET}${YELLOW}      #+++++++#  --## +++-.-++   #+-+#      ${RESET}${BOLD_YELLOW}2 0 1 0${RESET}"
  echo -e "${YELLOW}                               --+-+##++#+-+-+##++----+-.-----+#-.--.${RESET}"
  echo -e "${YELLOW} ################################${RESET}${BOLD_GREEN}.B.E.A.H.U.R.S.T...B.R.E.W.E.R.Y.${RESET}${YELLOW}#################################${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-............................${RESET}${YELLOW}##+#+#++####+#+#######+++#+#+#++++#+##${RESET}${RED}...........................-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-..+++++++++++++++++++++++++--${RESET}${YELLOW}+-#####+++--${RESET}${RED}............${RESET}${YELLOW}--+++#####-+${RESET}${RED}--+++++++++++++++++++++++++.-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-..+++++++++++++++++++++++++++++${RESET}${YELLOW}...${RESET}${RED}++++++++++++++++++++++++++${RESET}${YELLOW}...${RESET}${RED}+++++++++++++${RESET}..#${RED}+++++++++++++.-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-..++++++${RESET}.......#${RED}+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++${RESET}.#${RED}+++++++++++++.-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-..++++++${RESET}..######${RED}++++${RESET}..#${RED}++${RESET}..##${RED}++++${RESET}..#${RED}++++++++${RESET}..#${RED}++++++++${RESET}......#${RED}+++++${RESET}......${RED}++++++++${RESET}.....#${RED}+++++.-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-..++++++${RESET}.......#${RED}++++${RESET}..#${RED}++${RESET}..##${RED}++++${RESET}..#${RED}++++++++${RESET}..#${RED}++++++++${RESET}..#####${RED}+++++${RESET}..###..#${RED}+++++${RESET}..#####${RED}+++++.-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-..++++++${RESET}..######${RED}++++${RESET}..#${RED}++${RESET}..##${RED}++++${RESET}..#${RED}++++++++${RESET}..#${RED}++++++++${RESET}.....#${RED}++++++${RESET}......##${RED}++++++${RESET}....#${RED}++++++.-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-..++++++${RESET}..#${RED}+++++++++${RESET}..#${RED}++${RESET}..##${RED}++++${RESET}..#${RED}++++++++${RESET}..#${RED}++++++++${RESET}..####${RED}++++++${RESET}..#..#${RED}+++++++++${RESET}##...#${RED}++++.-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-..++++++${RESET}..#${RED}+++++++++${RESET}..#${RED}++${RESET}..#${RED}+++++${RESET}..#${RED}++++++++${RESET}..#${RED}++++++++.${RESET}.#${RED}+++++++++${RESET}..#${RED}+${RESET}..#${RED}+++++++++++${RESET}..#${RED}++++.-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-..++++++${RESET}..#${RED}++++++++++${RESET}.....##${RED}++++++${RESET}.....#${RED}++++${RESET}......#${RED}++++${RESET}......#${RED}+++++${RESET}.+#${RED}++${RESET}...#${RED}+++++${RESET}.....#${RED}+++++.-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-..++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++${RESET}..#${RED}+++++++++++++++.-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-..++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++.-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} #${RESET}${RED}-................................${RESET}${YELLOW}#############################${RESET}${RED}................................-+${RESET}${YELLOW}#${RESET}"
  echo -e "${YELLOW} ###################################${RESET}${BOLD_GREEN}...F...A...B...R...I...C...${RESET}${YELLOW}####################################${RESET}"
  echo -e "${YELLOW}                                   #############################${RESET}"
  echo ""
  echo "                                     WELCOME TO FULLER'S FABRIC"
  echo "                                     =========================="
  list_commands
else
  if [[ $1 =~ ^([^.:]+)\.?([^.:]+)?:?(.*)? ]]; then
    selected_group="${BASH_REMATCH[1]}"
    selected_subcommand="${BASH_REMATCH[2]}"
    options="${BASH_REMATCH[3]}"
  else
    echo "Couldn't parse command: \"$1\""
    echo "Try the format group.command:\"option1 option2 ...\""
    exit 1
  fi

  for group in "${!commands[@]}"; do
    if [[ $selected_group == $group ]]; then
      read -ra subcommands <<< "${commands[$group]}"
      if [[ $selected_subcommand ]]; then
        for subcommand in "${subcommands[@]}"; do
        if [[ $selected_subcommand == $subcommand ]]; then
          echo "Running command: \"$selected_group.$selected_subcommand $options\""
          run "$selected_subcommand" "$options"
          exit 0
        fi
        done
        echo "Could not find command \"$group.$selected_subcommand\"!"
        echo ""
        list_commands "$group"
        exit 1
      else
        selected_subcommand=${subcommands[0]}
        echo "Running command: \"$selected_group.$selected_subcommand $options\""
        run "$selected_subcommand" "$options"
        exit 0
      fi
    fi
  done
  echo "Could not find the command \"$selected_group\"!"
  echo ""
  list_commands
  exit 1
fi

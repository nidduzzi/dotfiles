s/[0-9][0-9]:[0-9][0-9] *$/HH:MM/
s/ in [0-9][0-9]*\.[0-9][0-9]*ms/ in DURATIONms/g
s/ in [0-9][0-9]*ms/ in DURATIONms/g
s/[0-9][0-9]*\.[0-9][0-9]*ms/DURATIONms/g
s/\([0-9][0-9]*\)\/\([0-9][0-9]*\) plugins/N\/N plugins/g
s|/home/[a-z0-9_-]*|~|g
s/⠋\|⠙\|⠹\|⠸\|⠼\|⠴\|⠦\|⠧\|⠇\|⠏/SPINNER/g
s|\([0-9][0-9]*\)/[0-9][0-9]* │|\1/TOTAL │|
s/ *[0-9][0-9]*//g
s/.*Loading workspace.*//
s/.*[0-9]\+%.*lua_ls.*//
s/[[:space:]]*$//
${s/  */ /g}

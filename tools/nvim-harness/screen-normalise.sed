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
# The showcmd area holds whatever keys are half-typed at the moment of
# capture, which depends on how fast the machine delivered them.
/ \(NORMAL\|INSERT\|VISUAL\|V-LINE\|V-BLOCK\|COMMAND\|TERMINAL\|REPLACE\|SELECT\) /s/<[0-9a-fA-F][0-9a-fA-F]>//g
/ \(NORMAL\|INSERT\|VISUAL\|V-LINE\|V-BLOCK\|COMMAND\|TERMINAL\|REPLACE\|SELECT\) /s/  */ /g
# A picker titled after the project is as wide as that project's path, and the
# path is replaced before this runs -- so the title's flanking rule varies by
# where the checkout happens to live while the text says PROJECT either way.
/╭.*\(PROJECT\|CONFIG\|BRANCH\).*╮/s/─\{2,\}/─/g

if status is-interactive
	# Commands to run in interactive sessions can go here
	function fish_prompt
		set -l last_status $status
		# Prompt status only if it's not 0
		set -l stat
		if test $last_status -ne 0
			set stat (set_color red)"[$last_status]"(set_color normal)
		end
		# The prompt
		string join '' -- (set_color red) (whoami)(set_color normal)@(set_color yellow)(hostname)(set_color green) (prompt_pwd) (set_color normal) $stat '>'
	end
end

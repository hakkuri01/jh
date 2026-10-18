# Entry point, and the only file under src/ that runs on require. Bare `jh` in a
# terminal runs the interactive program; with arguments it runs one scan through
# the one-shot CLI; with no arguments on a pipe it prints the static banner.
require "./jekyll_hyde/version"
require "./jekyll_hyde/render/logo"
require "./jekyll_hyde/render/graphics"
require "./jekyll_hyde/view/app"
require "./jekyll_hyde/entry"

if ARGV.empty?
  if STDOUT.tty?
    JekyllHyde::View::App.run
  else
    print JekyllHyde::Render::Logo.banner(false)
    puts "jh #{JekyllHyde::VERSION}"
  end
else
  exit JekyllHyde::Entry.run(ARGV)
end

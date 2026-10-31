# A wordlist file holding *words*, one per line, for any spec that needs a list
# on disk. The caller owns the file and deletes it.
def wordlist_file(*words : String) : String
  File.tempfile("jh_wl") { |file| words.each { |word| file.puts(word) } }.path
end

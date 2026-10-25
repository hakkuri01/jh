require "../tui/model"
require "./shell"

# The cockpit's field editing, split out of the App Elm model so neither file
# passes the size limit. INSERT-mode caret edits and NORMAL-mode field
# navigation: a cohesive unit that touches only the form's own state (@values,
# @field, @cursor, @editing), reopening App.
module JekyllHyde::View
  class App
    # INSERT: printable keys and Backspace/Delete edit at the caret, the arrows
    # and Home/End move the caret within the field, Enter runs the scan, and Esc
    # leaves INSERT for NORMAL.
    private def insert_key(name : String) : {Tui::Model, Tui::Cmd?}
      case name
      when "enter"     then execute
      when "esc"       then stop_editing
      when "left"      then move_cursor(-1)
      when "right"     then move_cursor(1)
      when "home"      then place_cursor(0)
      when "end"       then place_cursor(@values[@field].size)
      when "backspace" then delete_before_cursor
      when "delete"    then delete_at_cursor
      else                  insert_char(name)
      end
    end

    private def stop_editing : {Tui::Model, Tui::Cmd?}
      @editing = false
      {self, nil}
    end

    private def move_cursor(delta : Int32) : {Tui::Model, Tui::Cmd?}
      place_cursor(@cursor + delta)
    end

    # Clamp the caret into the focused field; insertions and deletes act at it.
    private def place_cursor(position : Int32) : {Tui::Model, Tui::Cmd?}
      @cursor = position.clamp(0, @values[@field].size)
      {self, nil}
    end

    private def insert_char(name : String) : {Tui::Model, Tui::Cmd?}
      return {self, nil} unless name.size == 1
      value = @values[@field]
      @values[@field] = value[0, @cursor] + name + value[@cursor..]
      @cursor += 1
      {self, nil}
    end

    private def delete_before_cursor : {Tui::Model, Tui::Cmd?}
      return {self, nil} if @cursor == 0
      value = @values[@field]
      @values[@field] = value[0, @cursor - 1] + value[@cursor..]
      @cursor -= 1
      {self, nil}
    end

    private def delete_at_cursor : {Tui::Model, Tui::Cmd?}
      value = @values[@field]
      return {self, nil} if @cursor >= value.size
      @values[@field] = value[0, @cursor] + value[(@cursor + 1)..]
      {self, nil}
    end

    private def move(delta : Int32) : {Tui::Model, Tui::Cmd?}
      @field = (@field + delta).clamp(0, Shell.fields(@mode).size - 1)
      {self, nil}
    end

    private def begin_insert : {Tui::Model, Tui::Cmd?}
      @editing = true
      @cursor = @values[@field].size
      {self, nil}
    end
  end
end

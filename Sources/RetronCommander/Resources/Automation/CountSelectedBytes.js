// Example Retron Automation script for OpenRetronCommander.
var items = Retron.SourcePanel.SelectedItems;
var total = 0;
for (var i = 0; i < items.Count; i++) {
    total += Number(items.Item(i).Size);
}
Retron.MsgBox(items.Count + " selected item(s), " + total + " bytes.");

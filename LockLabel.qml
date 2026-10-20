import QtQuick
import qs.Commons
import qs.Commons as Commons

// Plain-text label in the lock's colors and font, used by LockExtras.qml.
Text {
  textFormat: Text.PlainText
  color: Commons.Color.lock.text
  font.family: Style.font.family
  elide: Text.ElideRight
}

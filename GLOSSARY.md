# VPN Kill Switch

The menu describes the Mac’s VPN connection and the address visible to services on the internet.

## Language

**VPN Kill Switch**  
The product. Write “kill switch” in running text and “Kill Switch” in menu commands such as **Install Kill Switch**.  
_Avoid:_ Killswitch, killswitch.

**Selected VPN client**  
The VPN application chosen in Settings. It becomes the applied VPN client only after **Apply**.

**Applied VPN client**  
The VPN application saved in the service profile. With protection on, the guard allows only its connected tunnel.  
_Code:_ `saved_client` in shell becomes `applied_client`.

**VPN server**  
The IPv4 address, port and transport configured in a VPN client for connecting to its server. It can differ from the external IPv4.  
_Code:_ `Peer` remains the internal type name.  
_Avoid:_ endpoint, peer and allowed server in UI, README and checker output.

**VPN server rule**  
The base PF rule that lets traffic to the applied VPN server pass outside the tunnel.  
_Avoid:_ direct exception.

**External IPv4**  
The public IPv4 address a remote service observes for a request from this Mac over its current network route.

**Exit country**  
The country or territory that the selected GeoIP database associates with the external IPv4 address.

**Direct IPv4 destination**  
An IPv4 host or network the Mac may contact through Wi-Fi or Ethernet even while the applied VPN client is disconnected.

**Exception**  
An entry on the **Exceptions** tab. Each exception is one direct IPv4 destination.

**Blocked**  
Protection is on and no tunnel is allowed. The menu shows **Internet blocked**, or **Direct exceptions only** when exceptions are configured.  
_Code:_ `GuardState.blocked`.

**Protection menu**

The top-level menu item includes a state label: **On**, **Internet blocked**, **Direct exceptions only**, **Off**, **Check tunnel**, **Check direct config**, **Check direct routes**, **Status unknown** or **Working…**. VoiceOver reads the same title.

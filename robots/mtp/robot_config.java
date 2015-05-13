/*
 * Automatically generated by jrpcgen 1.0.5 on 1/8/05 2:03 PM
 * jrpcgen is part of the "Remote Tea" ONC/RPC package for Java
 * See http://acplt.org/ks/remotetea.html for details
 */
package net.emulab;
import org.acplt.oncrpc.*;
import java.io.IOException;

public class robot_config implements XdrAble {
    public int id;
    public String hostname;

    public robot_config() {
    }

    public robot_config(XdrDecodingStream xdr)
           throws OncRpcException, IOException {
        xdrDecode(xdr);
    }

    public void xdrEncode(XdrEncodingStream xdr)
           throws OncRpcException, IOException {
        xdr.xdrEncodeInt(id);
        xdr.xdrEncodeString(hostname);
    }

    public void xdrDecode(XdrDecodingStream xdr)
           throws OncRpcException, IOException {
        id = xdr.xdrDecodeInt();
        hostname = xdr.xdrDecodeString();
    }

}
// End of robot_config.java
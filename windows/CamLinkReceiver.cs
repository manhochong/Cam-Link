using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace CamLink {
    sealed class Receiver : IDisposable {
        public const int Port=9443;
        readonly TcpListener listener;
        readonly string folder,auth;
        readonly X509Certificate2 cert;
        readonly Action<string> status;
        public Action<Transfer> Live;
        readonly SemaphoreSlim slots=new SemaphoreSlim(3);
        volatile bool stopped;
        public readonly string Password,Fingerprint;
        public sealed class Transfer {
            public string Id,Name,Note;
            public long Got,Size;
            public bool Finished,Ok;
            public double Rate;
        }
        public static string Hex(byte[] bytes){return BitConverter.ToString(bytes).Replace("-","").ToLowerInvariant();}
        static byte[] Random(int length){byte[] b=new byte[length];using(var r=RandomNumberGenerator.Create()){r.GetBytes(b);}return b;}
        public Receiver(IPAddress ip,string dest,string settings,Action<string> report,Action<Transfer> live=null){
            folder=Path.GetFullPath(dest);Directory.CreateDirectory(folder);
            status=report;Directory.CreateDirectory(settings);
            string identity=Path.Combine(settings,"identity.dat");
            if(!File.Exists(identity)){
                using(var rsa=new RSACng(2048)){
                    var req=new CertificateRequest("CN=Cam Link Receiver",rsa,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
                    using(var local=req.CreateSelfSigned(DateTimeOffset.Now.AddDays(-1),DateTimeOffset.Now.AddYears(5))){
                        var payload=Encoding.UTF8.GetBytes(Hex(Random(6))+"\n"+Convert.ToBase64String(local.Export(X509ContentType.Pfx)));
                        string tmp=identity+"."+Guid.NewGuid().ToString("N");
                        File.WriteAllBytes(tmp,ProtectedData.Protect(payload,null,DataProtectionScope.CurrentUser));
                        try{File.Move(tmp,identity);}finally{if(File.Exists(tmp))File.Delete(tmp);}
                    }
                }
            }
            var config=Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(identity),null,DataProtectionScope.CurrentUser)).Split('\n');
            Password=config[0];cert=new X509Certificate2(Convert.FromBase64String(config[1]),"",X509KeyStorageFlags.UserKeySet);
            using(var hash=SHA256.Create()){Fingerprint=Hex(hash.ComputeHash(cert.RawData));}
            auth="Basic "+Convert.ToBase64String(Encoding.UTF8.GetBytes("camlink:"+Password));
            Live=live;listener=new TcpListener(ip,Port);listener.Start(8);Task.Run((Action)Serve);
        }
        void Serve(){
            while(!stopped){
                try{
                    var client=listener.AcceptTcpClient();
                    if(!slots.Wait(0)){client.Close();continue;}
                    Task.Run(()=>{try{Handle(client);}catch(Exception){}finally{client.Close();slots.Release();}});
                }catch(SocketException){if(stopped)return;}
            }
        }
        static string Line(Stream stream){
            var data=new List<byte>();
            while(data.Count<8192){int b=stream.ReadByte();if(b<0)throw new EndOfStreamException();if(b==10)return Encoding.ASCII.GetString(data.ToArray()).TrimEnd('\r');data.Add((byte)b);}
            throw new IOException("Header too large");
        }
        static void Reply(Stream s,int code,string extra=""){
            byte[] head=Encoding.ASCII.GetBytes("HTTP/1.1 "+code+" Result\r\nContent-Length: 0\r\nConnection: close\r\n"+extra+"\r\n");
            s.Write(head,0,head.Length);s.Flush();
        }
        void Handle(TcpClient client){
            client.ReceiveTimeout=20000;client.SendTimeout=20000;
            using(var tls=new SslStream(client.GetStream(),false)){
                tls.AuthenticateAsServer(cert,false,SslProtocols.Tls12,false);
                var req=Line(tls).Split(' ');if(req.Length!=3){Reply(tls,400);return;}
                var headers=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
                for(int i=0;;i++){string line=Line(tls);if(line.Length==0)break;if(i>=64)throw new IOException();
                    int split=line.IndexOf(':');if(split<1)throw new IOException();headers.Add(line.Substring(0,split),line.Substring(split+1).Trim());}
                string value;if(!headers.TryGetValue("Authorization",out value)||value!=auth){Reply(tls,401);return;}
                if(req[0]=="HEAD"&&req[1]=="/inbox/"){Reply(tls,200,"X-CamLink-Receiver: 1\r\n");return;}
                if(!req[1].StartsWith("/inbox/",StringComparison.Ordinal)){Reply(tls,404);return;}
                string name=Uri.UnescapeDataString(req[1].Substring(7));
                if(!Regex.IsMatch(name,@"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,190}\.jpe?g$",RegexOptions.IgnoreCase)){Reply(tls,400);return;}
                string file=Path.Combine(folder,name);
                if(req[0]!="PUT"){Reply(tls,405);return;}
                long size;string expected;
                if(!headers.TryGetValue("Content-Length",out value)||!long.TryParse(value,out size)||size<1||size>512L*1024*1024||
                    !headers.TryGetValue("X-CamLink-SHA256",out expected)||!Regex.IsMatch(expected,"^[a-f0-9]{64}$")){Reply(tls,400);return;}
                if(headers.TryGetValue("Expect",out value)&&value.Equals("100-continue",StringComparison.OrdinalIgnoreCase)){
                    byte[] interim=Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n");tls.Write(interim,0,interim.Length);tls.Flush();}
                string id=Guid.NewGuid().ToString("N"),tmp=Path.Combine(folder,".camlink-"+id+".part");
                var started=DateTime.UtcNow;var mark=started;long got=0;
                try{
                    Notify(id,name,0,size,false,false,started);
                    using(var fs=new FileStream(tmp,FileMode.CreateNew,FileAccess.Write,FileShare.None)){
                        byte[] buf=new byte[131072];long left=size;
                        while(left>0){
                            if(stopped)throw new IOException();
                            int n=tls.Read(buf,0,(int)Math.Min(left,buf.Length));if(n<=0)throw new EndOfStreamException();
                            fs.Write(buf,0,n);left-=n;got+=n;
                            var now=DateTime.UtcNow;if((now-mark).TotalMilliseconds>=160){mark=now;Notify(id,name,got,size,false,false,started);}
                        }
                        fs.Flush(true);
                    }
                    if(Digest(tmp)!=expected){Notify(id,name,got,size,true,false,started);Reply(tls,422);return;}
                    try{File.Move(tmp,file);}catch(IOException){if(!File.Exists(file))throw;if(Digest(file)!=expected){Notify(id,name,got,size,true,false,started);Reply(tls,409);return;}}
                    Reply(tls,201,"X-CamLink-SHA256: "+expected+"\r\n");
                    Notify(id,name,size,size,true,true,started);
                    status(DateTime.Now.ToString("HH:mm:ss")+"  已核對  "+name);
                }catch(Exception){
                    if(name!=null)Notify(id,name,got,size,true,false,started);
                    throw;
                }finally{if(File.Exists(tmp))File.Delete(tmp);}
            }
        }
        void Notify(string id,string name,long got,long size,bool finished,bool ok,DateTime started){
            try{
                var live=Live;if(live==null)return;
                double sec=Math.Max(0.05,(DateTime.UtcNow-started).TotalSeconds);
                live(new Transfer{Id=id,Name=name,Got=got,Size=size,Finished=finished,Ok=ok,Rate=got/1048576.0/sec,Note=finished?(ok?"已核對":"未核對"):"接收中"});
            }catch(Exception){}
        }
        static string Digest(string file){using(var sha=SHA256.Create())using(var input=File.OpenRead(file))return Hex(sha.ComputeHash(input));}
        public void Dispose(){stopped=true;listener.Stop();}
    }
    static class QrCode {
        static readonly byte[] Exp=new byte[512];
        static readonly int[] Log=new int[256];
        static readonly int[] FormatM={0x5412,0x5125,0x5e7c,0x5b4b,0x45f9,0x40ce,0x4f97,0x4aa0};
        static QrCode(){
            int x=1;
            for(int i=0;i<255;i++){Exp[i]=(byte)x;Log[x]=i;x<<=1;if((x&0x100)!=0)x^=0x11d;}
            for(int i=255;i<512;i++)Exp[i]=Exp[i-255];
        }
        static byte Mul(int a,int b){if(a==0||b==0)return 0;return Exp[Log[a]+Log[b]];}
        static byte[] Generator(int ecc){
            var poly=new byte[]{1};
            for(int i=0;i<ecc;i++){
                var next=new byte[poly.Length+1];
                for(int j=0;j<poly.Length;j++){next[j]^=poly[j];next[j+1]^=Mul(poly[j],Exp[i]);}
                poly=next;
            }
            var gen=new byte[ecc];Array.Copy(poly,1,gen,0,ecc);return gen;
        }
        static byte[] ReedSolomon(byte[] data,int ecc){
            var gen=Generator(ecc);var work=new byte[data.Length+ecc];Array.Copy(data,work,data.Length);
            for(int i=0;i<data.Length;i++){int coef=work[i];if(coef==0)continue;for(int j=0;j<ecc;j++)work[i+1+j]^=Mul(gen[j],coef);}
            var outp=new byte[ecc];Array.Copy(work,data.Length,outp,0,ecc);return outp;
        }
        public static bool[,] Modules(string text){
            byte[] raw=Encoding.UTF8.GetBytes(text);
            int version=raw.Length<=26?2:raw.Length<=42?3:4;
            if(raw.Length>62)throw new ArgumentException("QR payload too long");
            int blocks=version==4?2:1,dataLen=version==2?28:version==3?44:32,eccLen=version==2?16:version==3?26:18;
            var bits=new List<bool>();
            Add(bits,0x4,4);Add(bits,raw.Length,8);
            foreach(byte b in raw)Add(bits,b,8);
            int capacity=blocks*dataLen*8;
            for(int i=0;i<4&&bits.Count<capacity;i++)bits.Add(false);
            while(bits.Count%8!=0)bits.Add(false);
            var data=new byte[blocks*dataLen];
            for(int i=0;i<bits.Count/8;i++){int v=0;for(int b=0;b<8;b++)if(bits[i*8+b])v|=1<<(7-b);data[i]=(byte)v;}
            for(int i=bits.Count/8,pad=0;i<data.Length;i++,pad++)data[i]=(byte)(pad%2==0?0xEC:0x11);
            var message=new List<byte>();
            var ecc=new byte[blocks][];
            for(int b=0;b<blocks;b++){var block=new byte[dataLen];Array.Copy(data,b*dataLen,block,0,dataLen);ecc[b]=ReedSolomon(block,eccLen);}
            for(int i=0;i<dataLen;i++)for(int b=0;b<blocks;b++)message.Add(data[b*dataLen+i]);
            for(int i=0;i<eccLen;i++)for(int b=0;b<blocks;b++)message.Add(ecc[b][i]);
            var stream=new List<bool>();
            foreach(byte b in message)Add(stream,b,8);
            for(int i=0;i<7;i++)stream.Add(false);
            int size=17+version*4;
            var matrix=new int[size][];
            for(int r=0;r<size;r++){matrix[r]=new int[size];for(int c=0;c<size;c++)matrix[r][c]=2;}
            for(int i=0;i<9;i++){matrix[i][8]=0;matrix[8][i]=0;}
            for(int i=0;i<8;i++){matrix[size-1-i][8]=0;matrix[8][size-1-i]=0;}
            int bit=1;for(int i=8;i<size-8;i++){matrix[6][i]=matrix[i][6]=bit;bit^=1;}
            Finder(matrix,0,0);Finder(matrix,0,size-7);Finder(matrix,size-7,0);
            int[] align=version==2?new[]{6,18}:version==3?new[]{6,22}:new[]{6,26};
            foreach(int y in align)foreach(int x in align){
                if((x==6&&y==6)||(x==6&&y==align[align.Length-1])||(y==6&&x==align[align.Length-1]))continue;
                for(int dy=-2;dy<=2;dy++)for(int dx=-2;dx<=2;dx++)matrix[y+dy][x+dx]=(Math.Max(Math.Abs(dx),Math.Abs(dy))!=1)?1:0;
            }
            var region=new bool[size,size];
            for(int r=0;r<size;r++)for(int c=0;c<size;c++)region[r,c]=matrix[r][c]==2;
            int idx=0;
            for(int step=size-1;step>0;step-=2){
                int right=step;if(right<=6)right--;
                for(int vertical=0;vertical<size;vertical++)for(int z=0;z<2;z++){
                    int col=right-z;bool up=((right&2)==0)^(col<6);int row=up?size-1-vertical:vertical;
                    if(matrix[row][col]==2&&idx<stream.Count){matrix[row][col]=stream[idx]?1:0;idx++;}
                }
            }
            if(idx!=stream.Count)throw new InvalidOperationException("QR placement "+idx+"/"+stream.Count);
            for(int r=0;r<size;r++)for(int c=0;c<size;c++)if(region[r,c]){if(matrix[r][c]==2)matrix[r][c]=0;if(((r+c)&1)==0)matrix[r][c]^=1;}
            int format=FormatM[0],vOff=0,hOff=0;
            for(int i=0;i<8;i++){
                int vbit=(format>>i)&1,hbit=(format>>(14-i))&1;
                if(i==6){vOff++;hOff=1;}
                matrix[i+vOff][8]=vbit;matrix[8][i+hOff]=hbit;matrix[8][size-1-i]=vbit;matrix[size-1-i][8]=hbit;
            }
            matrix[size-8][8]=1;
            var modules=new bool[size,size];
            for(int r=0;r<size;r++)for(int c=0;c<size;c++)modules[r,c]=matrix[r][c]==1;
            return modules;
        }
        static void Add(List<bool> bits,int value,int count){for(int i=count-1;i>=0;i--)bits.Add(((value>>i)&1)==1);}
        static void Finder(int[][] matrix,int row,int col){
            for(int r=0;r<7;r++)for(int c=0;c<7;c++){
                bool edge=r==0||r==6||c==0||c==6,core=r>=2&&r<=4&&c>=2&&c<=4;
                matrix[row+r][col+c]=edge||core?1:0;
            }
            for(int i=-1;i<=7;i++){
                if(row+i>=0&&row+i<matrix.Length){if(col-1>=0)matrix[row+i][col-1]=0;if(col+7<matrix.Length)matrix[row+i][col+7]=0;}
                if(col+i>=0&&col+i<matrix.Length){if(row-1>=0)matrix[row-1][col+i]=0;if(row+7<matrix.Length)matrix[row+7][col+i]=0;}
            }
        }
        public static string Dump(string text){
            var m=Modules(text);int n=m.GetLength(0);var lines=new string[n];
            for(int r=0;r<n;r++){var s=new char[n];for(int c=0;c<n;c++)s[c]=m[r,c]?'1':'0';lines[r]=new string(s);}
            return string.Join("\n",lines);
        }
    }
    sealed class Window : Form {
        const string Version="0.2.25";
        static readonly Color Paper=Color.FromArgb(244,246,248),Ink=Color.FromArgb(28,30,33),Gray=Color.FromArgb(138,144,153),Soft=Color.White,Photo=Color.FromArgb(69,71,74),Accent=Color.FromArgb(255,107,26),Warm=Color.FromArgb(255,132,48),Line=Color.FromArgb(226,229,234),Faint=Color.FromArgb(186,188,192);
        readonly ComboBox ips=new ComboBox();readonly TextBox folder=new TextBox();
        readonly Button run=new Button(),browse=new Button(),openFolder=new Button(),showQr=new Button();
        readonly PictureBox picture=new PictureBox();
        readonly Label caption=new Label(),state=new Label(),current=new Label(),speed=new Label();
        readonly Label received=new Label(),active=new Label(),verified=new Label(),address=new Label(),code=new Label(),finger=new Label(),fileCount=new Label(),emptyFiles=new Label();
        TableLayoutPanel fileHead;
        readonly Panel meter=new Panel(),fill=new Panel();
        bool[,] modules;string pairHost="",pairCode="",pairPrint="";bool pairVisible;
        Form qrWindow;
        readonly ListView arrivals=new ListView();
        readonly Dictionary<string,ListViewItem> rows=new Dictionary<string,ListViewItem>();
        readonly string settings=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"CamLinkReceiver");
        Receiver receiver;MemoryStream photoHold,logoHold;int gotCount,busyCount;long verifiedBytes;DateTime sessionStart;string shown="";
        Font titleFont,stateFont,metricFont,codeFont,fingerFont,smallFont,placeholderFont,addressFont;
        public Window(){
            Text="Cam Link";Width=1240;Height=820;MinimumSize=new Size(1080,780);StartPosition=FormStartPosition.CenterScreen;
            BackColor=Paper;ForeColor=Ink;Font=new Font("Microsoft JhengHei UI",10);AutoScaleMode=AutoScaleMode.Dpi;DoubleBuffered=true;
            titleFont=new Font("Microsoft JhengHei UI",18,FontStyle.Bold);
            stateFont=new Font("Microsoft JhengHei UI",18,FontStyle.Bold);
            metricFont=new Font("Microsoft JhengHei UI",18,FontStyle.Bold);
            codeFont=new Font("Consolas",16,FontStyle.Bold);
            fingerFont=new Font("Consolas",12);
            smallFont=new Font("Microsoft JhengHei UI",9);
            placeholderFont=new Font("Microsoft JhengHei UI",16);
            addressFont=new Font("Microsoft JhengHei UI",12,FontStyle.Bold);
            try{Icon=Icon.ExtractAssociatedIcon(Application.ExecutablePath);}catch(Exception){}
            var head=BuildHead();
            var stage=BuildStage();
            Controls.Add(stage);
            Controls.Add(head);
            run.Click+=(o,e)=>Toggle();
            FormClosing+=(o,e)=>Stop();
            Shown+=(o,e)=>FitColumns();
            arrivals.Resize+=(o,e)=>FitColumns();
        }
        Panel BuildHead(){
            var head=new Panel{Dock=DockStyle.Top,Height=68,BackColor=Paper,Padding=new Padding(28,14,28,10)};
            var row=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=3,RowCount=1,BackColor=Paper,Margin=new Padding(0),Padding=new Padding(0)};
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,48));
            row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
            row.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            var mark=new PictureBox{Size=new Size(40,40),Margin=new Padding(0),Anchor=AnchorStyles.Left,SizeMode=PictureBoxSizeMode.Zoom,BackColor=Paper};
            try{
                using(var resource=System.Reflection.Assembly.GetExecutingAssembly().GetManifestResourceStream("CamLink.logo.png")){
                    if(resource!=null){
                        logoHold=new MemoryStream();
                        resource.CopyTo(logoHold);
                        logoHold.Position=0;
                        mark.Image=Image.FromStream(logoHold);
                    }
                }
            }catch(Exception){}
            var title=new Label{Text="Cam Link",AutoSize=true,Anchor=AnchorStyles.Left,Font=titleFont,ForeColor=Ink,Margin=new Padding(0,0,12,0),UseMnemonic=false};
            var sub=new Label{Text="電腦收相    "+Version,AutoSize=true,Anchor=AnchorStyles.Left,Font=smallFont,ForeColor=Gray,Margin=new Padding(0,8,0,0),UseMnemonic=false};
            row.Controls.Add(mark,0,0);row.Controls.Add(title,1,0);row.Controls.Add(sub,2,0);
            head.Controls.Add(row);
            return head;
        }
        Control BuildStage(){
            var stage=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=1,BackColor=Paper,Padding=new Padding(24,20,24,16),Margin=new Padding(0)};
            stage.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,70));
            stage.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,30));
            stage.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            var left=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=2,BackColor=Paper,Margin=new Padding(0,0,16,0),Padding=new Padding(0),GrowStyle=TableLayoutPanelGrowStyle.FixedSize};
            left.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
            left.RowStyles.Add(new RowStyle(SizeType.Percent,70));
            left.RowStyles.Add(new RowStyle(SizeType.Percent,30));
            var frame=new Panel{Dock=DockStyle.Fill,BackColor=Photo,Margin=new Padding(0,0,0,12)};
            Round(frame,22);
            var well=new Panel{Dock=DockStyle.Fill,BackColor=Photo,Padding=new Padding(12),Margin=new Padding(0)};
            picture.Dock=DockStyle.Fill;picture.BackColor=Photo;picture.Margin=new Padding(0);picture.SizeMode=PictureBoxSizeMode.Zoom;
            picture.Paint+=(o,e)=>{
                if(picture.Image!=null||picture.ClientRectangle.Width<8||picture.ClientRectangle.Height<8)return;
                var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;
                var area=picture.ClientRectangle;
                int cx=area.Width/2,cy=area.Height/2-18,d=64;
                using(var brush=new SolidBrush(Color.FromArgb(86,88,92)))g.FillEllipse(brush,cx-d/2,cy-d/2,d,d);
                using(var pen=new Pen(Color.FromArgb(198,200,204),1.6f)){
                    g.DrawRectangle(pen,cx-11,cy-8,22,16);
                    g.DrawLine(pen,cx-7,cy+8,cx-2,cy+1);g.DrawLine(pen,cx-2,cy+1,cx+2,cy+5);g.DrawLine(pen,cx+2,cy+5,cx+11,cy-4);
                    g.DrawEllipse(pen,cx+4,cy-5,4,4);
                }
                TextRenderer.DrawText(g,"等待第一張照片",placeholderFont,new Rectangle(0,cy+d/2+8,area.Width,36),Faint,TextFormatFlags.HorizontalCenter|TextFormatFlags.Top|TextFormatFlags.NoPadding);
            };
            well.Controls.Add(picture);
            caption.Dock=DockStyle.Bottom;caption.Height=34;caption.Margin=new Padding(0);caption.AutoSize=false;caption.AutoEllipsis=true;caption.UseMnemonic=false;
            caption.ForeColor=Color.FromArgb(250,246,238);caption.BackColor=Color.FromArgb(210,20,20,20);
            caption.TextAlign=ContentAlignment.MiddleLeft;caption.Padding=new Padding(14,0,14,0);caption.Visible=false;
            frame.Controls.Add(well);frame.Controls.Add(caption);
            left.Controls.Add(frame,0,0);
            left.Controls.Add(BuildFiles(),0,1);
            var card=BuildCard();
            var setup=BuildSetup();
            card.Dock=DockStyle.Fill;card.Margin=new Padding(0);
            setup.Dock=DockStyle.Fill;setup.Margin=new Padding(0);
            var right=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=1,RowCount=5,BackColor=Paper,Margin=new Padding(0),Padding=new Padding(0),GrowStyle=TableLayoutPanelGrowStyle.FixedSize};
            right.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
            right.RowStyles.Add(new RowStyle(SizeType.Absolute,card.Height));
            right.RowStyles.Add(new RowStyle(SizeType.Absolute,16));
            right.RowStyles.Add(new RowStyle(SizeType.Absolute,setup.Height));
            right.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            right.RowStyles.Add(new RowStyle(SizeType.Absolute,68));
            var runHost=new Panel{Dock=DockStyle.Fill,BackColor=Paper,Margin=new Padding(0),Padding=new Padding(0,16,0,0)};
            run.Text="開始接收";run.Dock=DockStyle.Fill;run.Margin=new Padding(0);run.FlatStyle=FlatStyle.Flat;run.UseVisualStyleBackColor=false;run.FlatAppearance.BorderSize=0;run.BackColor=Warm;run.ForeColor=Color.White;run.Font=new Font(Font,FontStyle.Bold);run.Cursor=Cursors.Hand;run.Padding=new Padding(22,0,0,0);
            run.Paint+=(o,e)=>{
                if(run.Text!="開始接收")return;
                var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;
                int d=18,x=run.ClientSize.Width/2-58,y=(run.ClientSize.Height-d)/2;
                using(var brush=new SolidBrush(Color.White))g.FillEllipse(brush,x,y,d,d);
                using(var brush=new SolidBrush(run.BackColor))g.FillPolygon(brush,new[]{new Point(x+7,y+5),new Point(x+13,y+9),new Point(x+7,y+13)});
            };
            Round(run,18);
            runHost.Controls.Add(run);
            right.Controls.Add(card,0,0);
            right.Controls.Add(new Panel{Dock=DockStyle.Fill,BackColor=Paper,Margin=new Padding(0)},0,1);
            right.Controls.Add(setup,0,2);
            right.Controls.Add(new Panel{Dock=DockStyle.Fill,BackColor=Paper,Margin=new Padding(0)},0,3);
            right.Controls.Add(runHost,0,4);
            stage.Controls.Add(left,0,0);
            stage.Controls.Add(right,1,0);
            return stage;
        }
        Control BuildCard(){
            var card=new Panel{Dock=DockStyle.Top,BackColor=Soft,Padding=new Padding(16,14,16,14),Margin=new Padding(0)};
            Card(card,18);
            var body=new TableLayoutPanel{Dock=DockStyle.Top,ColumnCount=1,BackColor=Soft,GrowStyle=TableLayoutPanelGrowStyle.FixedSize};
            FillRows(body,22,12,92,10,4,8,20,16,14,28,28,28,12,44);
            var title=new Panel{Dock=DockStyle.Fill,BackColor=Soft,Margin=new Padding(0)};
            var section=new Label{Text="連線狀態",Dock=DockStyle.Left,Width=88,Margin=new Padding(0),AutoSize=false,ForeColor=Gray,Font=smallFont,TextAlign=ContentAlignment.MiddleLeft,UseMnemonic=false,BackColor=Soft};
            state.Text="";state.Font=smallFont;state.ForeColor=Gray;state.Dock=DockStyle.Fill;state.Margin=new Padding(0);state.AutoSize=false;state.TextAlign=ContentAlignment.MiddleRight;state.UseMnemonic=false;state.BackColor=Soft;
            title.Controls.Add(state);title.Controls.Add(section);
            body.Controls.Add(title,0,0);
            body.Controls.Add(BuildMetrics(),0,2);
            meter.Dock=DockStyle.Fill;meter.Margin=new Padding(0);meter.BackColor=Line;fill.BackColor=Accent;fill.Location=new Point(0,0);fill.Size=new Size(0,4);meter.Controls.Add(fill);
            meter.Resize+=(o,e)=>{fill.Height=Math.Max(1,meter.ClientSize.Height);};
            body.Controls.Add(meter,0,4);
            current.Text="";current.Font=smallFont;current.ForeColor=Ink;current.Dock=DockStyle.Fill;current.Margin=new Padding(0);current.AutoSize=false;current.AutoEllipsis=true;current.UseMnemonic=false;current.TextAlign=ContentAlignment.MiddleLeft;current.BackColor=Soft;
            speed.Text="";speed.Font=smallFont;speed.ForeColor=Gray;speed.Dock=DockStyle.Fill;speed.Margin=new Padding(0);speed.AutoSize=false;speed.AutoEllipsis=true;speed.UseMnemonic=false;speed.TextAlign=ContentAlignment.MiddleLeft;speed.BackColor=Soft;
            body.Controls.Add(current,0,6);body.Controls.Add(speed,0,7);
            var facts=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=2,RowCount=3,BackColor=Soft,Margin=new Padding(0),Padding=new Padding(0),GrowStyle=TableLayoutPanelGrowStyle.FixedSize};
            facts.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,72));
            facts.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
            facts.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            facts.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            facts.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            facts.Controls.Add(Cap("手機地址"),0,0);
            address.Text="開始接收後顯示";StyleValue(address,smallFont);address.TextAlign=ContentAlignment.MiddleRight;address.Click+=(o,e)=>RevealPair();facts.Controls.Add(address,1,0);
            facts.Controls.Add(Cap("配對碼"),0,1);
            code.Text="—";StyleValue(code,smallFont);code.TextAlign=ContentAlignment.MiddleRight;code.Click+=(o,e)=>RevealPair();facts.Controls.Add(code,1,1);
            facts.Controls.Add(Cap("指紋"),0,2);
            finger.Text="與手機畫面上的 16 位比對";StyleValue(finger,smallFont);finger.TextAlign=ContentAlignment.MiddleRight;finger.AutoEllipsis=true;finger.Click+=(o,e)=>RevealPair();            facts.Controls.Add(finger,1,2);
            body.Controls.Add(facts,0,9);body.SetRowSpan(facts,3);
            showQr.Text="顯示 QR 掃描";showQr.Dock=DockStyle.Fill;showQr.Margin=new Padding(0);showQr.FlatStyle=FlatStyle.Flat;showQr.UseVisualStyleBackColor=false;showQr.BackColor=Color.White;showQr.ForeColor=Ink;showQr.FlatAppearance.BorderColor=Line;showQr.FlatAppearance.BorderSize=1;showQr.FlatAppearance.MouseOverBackColor=Color.White;showQr.FlatAppearance.MouseDownBackColor=Paper;showQr.Cursor=Cursors.Hand;
            showQr.Paint+=(o,e)=>{
                var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;
                using(var brush=new SolidBrush(Color.White))g.FillRectangle(brush,showQr.ClientRectangle);
                var box=showQr.ClientRectangle;box.Width-=1;box.Height-=1;
                using(var pen=new Pen(Line))using(var path=RoundPath(box,10))g.DrawPath(pen,path);
                int x=showQr.ClientSize.Width/2-78,y=showQr.ClientSize.Height/2-7;
                using(var brush=new SolidBrush(Ink)){
                    g.FillRectangle(brush,x,y,6,6);g.FillRectangle(brush,x+9,y,6,6);g.FillRectangle(brush,x,y+9,6,6);
                    g.FillRectangle(brush,x+3,y+3,2,2);g.FillRectangle(brush,x+12,y+3,2,2);g.FillRectangle(brush,x+3,y+12,2,2);
                    g.FillRectangle(brush,x+9,y+9,2,2);g.FillRectangle(brush,x+12,y+12,3,3);
                }
                TextRenderer.DrawText(g,"顯示 QR 掃描",Font,new Rectangle(x+22,0,120,showQr.ClientSize.Height),Ink,TextFormatFlags.Left|TextFormatFlags.VerticalCenter|TextFormatFlags.NoPadding);
            };
            Round(showQr,12);
            showQr.Click+=(o,e)=>OpenQr();
            body.Controls.Add(showQr,0,13);
            card.Controls.Add(body);
            card.Height=body.Height+28;
            return card;
        }
        Control BuildMetrics(){
            var counts=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=3,RowCount=1,BackColor=Soft,Margin=new Padding(0),Padding=new Padding(0),GrowStyle=TableLayoutPanelGrowStyle.FixedSize};
            counts.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,33.33f));
            counts.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,33.33f));
            counts.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,33.34f));
            counts.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            var verifiedTile=Tile(received,"已核對");verifiedTile.Margin=new Padding(0,0,8,0);
            var activeTile=Tile(active,"傳輸中");activeTile.Margin=new Padding(4,0,4,0);
            var bytesTile=Tile(verified,"MB");bytesTile.Margin=new Padding(8,0,0,0);
            counts.Controls.Add(verifiedTile,0,0);
            counts.Controls.Add(activeTile,1,0);
            counts.Controls.Add(bytesTile,2,0);
            SetCount();
            return counts;
        }
        Panel Tile(Label value,string caption){
            var tile=new Panel{Dock=DockStyle.Fill,BackColor=Soft,Margin=new Padding(0),Padding=new Padding(4,6,4,4)};
            Card(tile,14);
            var cap=new Label{Text=caption,Dock=DockStyle.Bottom,Height=22,Margin=new Padding(0),AutoSize=false,ForeColor=Gray,Font=smallFont,TextAlign=ContentAlignment.TopCenter,UseMnemonic=false,BackColor=Soft};
            value.Dock=DockStyle.Fill;value.Margin=new Padding(0);value.AutoSize=false;value.ForeColor=Ink;value.Font=metricFont;value.TextAlign=ContentAlignment.BottomCenter;value.UseMnemonic=false;value.BackColor=Soft;
            tile.Controls.Add(value);tile.Controls.Add(cap);
            return tile;
        }
        Panel BuildFiles(){
            var files=new Panel{Dock=DockStyle.Fill,BackColor=Soft,Padding=new Padding(16,10,16,12),Margin=new Padding(0)};
            Card(files,18);
            var head=new Panel{Dock=DockStyle.Top,Height=32,BackColor=Soft,Margin=new Padding(0)};
            var heading=new Label{Text="本輪檔案",Dock=DockStyle.Left,Width=120,Margin=new Padding(0),AutoSize=false,ForeColor=Ink,Font=new Font(Font,FontStyle.Bold),TextAlign=ContentAlignment.MiddleLeft,UseMnemonic=false,BackColor=Soft,Padding=new Padding(22,0,0,0)};
            head.Paint+=(o,e)=>{
                var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;
                using(var pen=new Pen(Gray,1.4f)){g.DrawRectangle(pen,1,8,14,16);g.DrawLine(pen,4,13,12,13);g.DrawLine(pen,4,17,10,17);}
            };
            fileCount.Text="共 0 個檔案";fileCount.Dock=DockStyle.Fill;fileCount.Margin=new Padding(0);fileCount.AutoSize=false;fileCount.ForeColor=Gray;fileCount.Font=smallFont;fileCount.TextAlign=ContentAlignment.MiddleRight;fileCount.UseMnemonic=false;fileCount.BackColor=Soft;
            head.Controls.Add(fileCount);head.Controls.Add(heading);
            fileHead=new TableLayoutPanel{Dock=DockStyle.Top,Height=26,ColumnCount=5,RowCount=1,BackColor=Soft,Margin=new Padding(0),Padding=new Padding(0)};
            foreach(var name in new[]{"時間","檔名","大小","速度","狀態"}){
                fileHead.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,name=="檔名"?40:15));
                var h=new Label{Text=name,Dock=DockStyle.Fill,Margin=new Padding(0),AutoSize=false,ForeColor=Gray,Font=smallFont,TextAlign=ContentAlignment.MiddleLeft,UseMnemonic=false,BackColor=Soft};
                fileHead.Controls.Add(h);
            }
            emptyFiles.Text="尚無傳輸紀錄";emptyFiles.Dock=DockStyle.Fill;emptyFiles.Margin=new Padding(0);emptyFiles.AutoSize=false;emptyFiles.ForeColor=Gray;emptyFiles.Font=Font;emptyFiles.TextAlign=ContentAlignment.MiddleCenter;emptyFiles.UseMnemonic=false;emptyFiles.BackColor=Soft;emptyFiles.Padding=new Padding(0,36,0,0);
            emptyFiles.Paint+=(o,e)=>{
                var g=e.Graphics;g.SmoothingMode=SmoothingMode.AntiAlias;
                int x=emptyFiles.Width/2-12,y=Math.Max(8,emptyFiles.Height/2-34);
                using(var pen=new Pen(Color.FromArgb(186,194,204),1.6f)){
                    g.DrawRectangle(pen,x,y+6,24,16);
                    g.DrawLine(pen,x,y+6,x+8,y);g.DrawLine(pen,x+8,y,x+16,y+6);g.DrawLine(pen,x+16,y+6,x+24,y);
                }
            };
            arrivals.Dock=DockStyle.Fill;arrivals.Margin=new Padding(0);arrivals.View=View.Details;arrivals.FullRowSelect=true;arrivals.BorderStyle=BorderStyle.None;arrivals.HeaderStyle=ColumnHeaderStyle.Nonclickable;arrivals.BackColor=Soft;arrivals.ForeColor=Ink;arrivals.Font=smallFont;arrivals.ShowItemToolTips=true;
            arrivals.Columns.Add("時間",72);arrivals.Columns.Add("檔名",160);arrivals.Columns.Add("大小",88);arrivals.Columns.Add("速度",72);arrivals.Columns.Add("狀態",72);
            files.Controls.Add(emptyFiles);files.Controls.Add(arrivals);files.Controls.Add(fileHead);files.Controls.Add(head);
            SetCount();
            return files;
        }
        Panel BuildSetup(){
            var setup=new Panel{Dock=DockStyle.Top,BackColor=Soft,Margin=new Padding(0),Padding=new Padding(16,14,16,14)};
            Card(setup,18);
            var grid=new TableLayoutPanel{Dock=DockStyle.Top,ColumnCount=1,BackColor=Soft,Margin=new Padding(0),Padding=new Padding(0),GrowStyle=TableLayoutPanelGrowStyle.FixedSize};
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
            FillRows(grid,18,36,12,22,36);
            grid.Controls.Add(FieldLabel("這部電腦的網絡"),0,0);
            ips.DropDownStyle=ComboBoxStyle.DropDownList;ips.FlatStyle=FlatStyle.Flat;ips.Margin=new Padding(0);ips.Dock=DockStyle.Fill;ips.BackColor=Soft;
            foreach(var nic in NetworkInterface.GetAllNetworkInterfaces().Where(n=>n.OperationalStatus==OperationalStatus.Up))
                foreach(var a in nic.GetIPProperties().UnicastAddresses.Where(a=>a.Address.AddressFamily==AddressFamily.InterNetwork&&!IPAddress.IsLoopback(a.Address)))ips.Items.Add(a.Address);
            if(ips.Items.Count>0)ips.SelectedIndex=0;
            grid.Controls.Add(ips,0,1);
            var folderHead=new Panel{Dock=DockStyle.Fill,BackColor=Soft,Margin=new Padding(0)};
            var folderLabel=FieldLabel("JPG 儲存資料夾");
            openFolder.Text="開啟資料夾";openFolder.AutoSize=false;openFolder.Dock=DockStyle.Right;openFolder.Width=88;openFolder.FlatStyle=FlatStyle.Flat;openFolder.UseVisualStyleBackColor=false;openFolder.BackColor=Soft;openFolder.ForeColor=Accent;openFolder.FlatAppearance.BorderSize=0;openFolder.Cursor=Cursors.Hand;openFolder.TextAlign=ContentAlignment.MiddleRight;
            openFolder.Click+=(o,e)=>OpenSavedFolder();
            folderHead.Controls.Add(folderLabel);folderHead.Controls.Add(openFolder);
            grid.Controls.Add(folderHead,0,3);
            var pathRow=new TableLayoutPanel{Dock=DockStyle.Fill,ColumnCount=3,RowCount=1,BackColor=Soft,Margin=new Padding(0),Padding=new Padding(0),GrowStyle=TableLayoutPanelGrowStyle.FixedSize};
            pathRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent,100));
            pathRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,8));
            pathRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute,72));
            pathRow.RowStyles.Add(new RowStyle(SizeType.Percent,100));
            string remembered=Path.Combine(settings,"folder.txt");
            folder.Text=File.Exists(remembered)?File.ReadAllText(remembered).Trim():Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),"Cam Link");
            if(folder.Text.Length==0)folder.Text=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),"Cam Link");
            folder.BorderStyle=BorderStyle.FixedSingle;folder.Margin=new Padding(0);folder.Dock=DockStyle.Fill;folder.BackColor=Soft;
            pathRow.Controls.Add(folder,0,0);
            QuietButton(browse,"選擇");
            browse.Click+=(o,e)=>{using(var pick=new FolderBrowserDialog())if(pick.ShowDialog()==DialogResult.OK)folder.Text=pick.SelectedPath;};
            pathRow.Controls.Add(browse,2,0);
            grid.Controls.Add(pathRow,0,4);
            setup.Controls.Add(grid);
            setup.Height=grid.Height+28;
            return setup;
        }
        static GraphicsPath RoundPath(Rectangle bounds,int radius){
            int d=Math.Max(2,radius*2);var path=new GraphicsPath();
            path.AddArc(bounds.X,bounds.Y,d,d,180,90);
            path.AddArc(bounds.Right-d,bounds.Y,d,d,270,90);
            path.AddArc(bounds.Right-d,bounds.Bottom-d,d,d,0,90);
            path.AddArc(bounds.X,bounds.Bottom-d,d,d,90,90);
            path.CloseFigure();return path;
        }
        void Round(Control control,int radius){
            Action apply=()=>{var b=control.ClientRectangle;if(b.Width<8||b.Height<8)return;control.Region=new Region(RoundPath(b,radius));};
            control.Resize+=(o,e)=>apply();control.HandleCreated+=(o,e)=>apply();
        }
        void Card(Panel panel,int radius){
            panel.BackColor=Soft;Round(panel,radius);
            panel.Paint+=(o,e)=>{
                var b=panel.ClientRectangle;b.Width-=1;b.Height-=1;if(b.Width<8||b.Height<8)return;
                e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
                using(var pen=new Pen(Line))using(var path=RoundPath(b,radius))e.Graphics.DrawPath(pen,path);
            };
        }
        static void FillRows(TableLayoutPanel table,params int[] heights){
            table.RowCount=heights.Length;table.Margin=new Padding(0);table.Padding=new Padding(0);table.RowStyles.Clear();
            int sum=0;for(int i=0;i<heights.Length;i++){table.RowStyles.Add(new RowStyle(SizeType.Absolute,heights[i]));sum+=heights[i];}
            table.Height=sum;
        }
        void QuietButton(Button button,string text){
            button.Text=text;button.Dock=DockStyle.Fill;button.Margin=new Padding(0,2,0,2);button.FlatStyle=FlatStyle.Flat;button.UseVisualStyleBackColor=false;
            button.BackColor=Paper;button.ForeColor=Ink;button.FlatAppearance.BorderColor=Line;button.FlatAppearance.BorderSize=1;button.Cursor=Cursors.Hand;
            Round(button,10);
        }
        Label FieldLabel(string text){return new Label{Text=text,Dock=DockStyle.Fill,Margin=new Padding(0),AutoSize=false,ForeColor=Gray,Font=smallFont,TextAlign=ContentAlignment.BottomLeft,UseMnemonic=false};}
        Label Cap(string text){return new Label{Text=text,Dock=DockStyle.Fill,Margin=new Padding(0),AutoSize=false,ForeColor=Gray,Font=smallFont,TextAlign=ContentAlignment.MiddleLeft,UseMnemonic=false};}
        void StyleValue(Label value,Font font){value.Dock=DockStyle.Fill;value.Margin=new Padding(0);value.AutoSize=false;value.AutoEllipsis=false;value.ForeColor=Ink;value.Font=font;value.TextAlign=ContentAlignment.MiddleLeft;value.UseMnemonic=false;}
        void FitColumns(){
            if(arrivals.Columns.Count<5)return;
            int used=arrivals.Columns[0].Width+arrivals.Columns[2].Width+arrivals.Columns[3].Width+arrivals.Columns[4].Width+8;
            int name=arrivals.ClientSize.Width-used;
            if(name>160)arrivals.Columns[1].Width=name;
        }
        void SetCount(){
            received.Text=gotCount.ToString();active.Text=busyCount.ToString();verified.Text=(verifiedBytes/1048576.0).ToString("0.0");
            int n=arrivals.Items.Count;fileCount.Text="共 "+n+" 個檔案";bool any=n>0;
            arrivals.Visible=any;emptyFiles.Visible=!any;if(fileHead!=null)fileHead.Visible=!any;
        }
        void Toggle(){
            if(receiver!=null){Stop();return;}
            try{
                if(ips.SelectedItem==null||String.IsNullOrWhiteSpace(folder.Text))throw new IOException("請選擇本機網絡及收相資料夾");
                Directory.CreateDirectory(settings);File.WriteAllText(Path.Combine(settings,"folder.txt"),folder.Text.Trim());
                rows.Clear();arrivals.Items.Clear();gotCount=busyCount=0;verifiedBytes=0;sessionStart=DateTime.UtcNow;shown="";SetCount();ShowPhoto(null,"");
                receiver=new Receiver((IPAddress)ips.SelectedItem,folder.Text.Trim(),settings,s=>{},OnLive);
                ShowPair(ips.SelectedItem+":9443",receiver.Password,receiver.Fingerprint.Substring(0,16).ToUpperInvariant(),"camlink://pair?ip="+ips.SelectedItem+"&code="+receiver.Password);
                state.Text="可以接收";current.Text="等待手機傳來的 JPG";speed.Text="按「顯示 QR」配對，指紋必須相同";fill.Width=0;
                run.Text="停止接收";run.BackColor=Ink;run.ForeColor=Color.White;ips.Enabled=folder.Enabled=browse.Enabled=false;
            }catch(Exception ex){if(receiver!=null){receiver.Dispose();receiver=null;}MessageBox.Show(ex.Message,"無法啟動");}
        }
        void OnLive(Receiver.Transfer transfer){
            if(IsDisposed)return;
            if(InvokeRequired){BeginInvoke((Action)(()=>OnLive(transfer)));return;}
            ListViewItem row;if(!rows.TryGetValue(transfer.Id,out row)){
                row=new ListViewItem(DateTime.Now.ToString("HH:mm:ss"));row.SubItems.Add(transfer.Name);row.SubItems.Add("");row.SubItems.Add("");row.SubItems.Add("接收中");
                arrivals.Items.Insert(0,row);rows[transfer.Id]=row;busyCount++;
            }
            row.SubItems[2].Text=Amount(transfer.Got)+" / "+Amount(transfer.Size);
            row.SubItems[3].Text=transfer.Rate.ToString("0.0")+" MB/s";
            row.SubItems[4].Text=transfer.Note;
            if(transfer.Finished&&row.Tag==null){row.Tag="done";busyCount=Math.Max(0,busyCount-1);if(transfer.Ok){gotCount++;verifiedBytes+=transfer.Size;ShowPhoto(Path.Combine(folder.Text.Trim(),transfer.Name),transfer.Name);}}
            double span=Math.Max(0.05,(DateTime.UtcNow-sessionStart).TotalSeconds);
            state.Text=busyCount>0?"正在接收":gotCount>0?"剛核對一張":"可以接收";
            current.Text=transfer.Finished&&transfer.Ok?transfer.Name:transfer.Name;
            speed.Text=Amount(transfer.Got)+" / "+Amount(transfer.Size)+"    "+transfer.Rate.ToString("0.0")+" MB/s    全程 "+(verifiedBytes/1048576.0/span).ToString("0.0")+" MB/s";
            int width=transfer.Size<=0?0:(int)(meter.Width*Math.Min(1,transfer.Got/(double)transfer.Size));
            fill.Width=Math.Max(0,width);SetCount();
        }
        void ShowPhoto(string path,string name){
            if(string.IsNullOrEmpty(path)){var oldImage=picture.Image;var oldStream=photoHold;picture.Image=null;photoHold=null;if(oldImage!=null)oldImage.Dispose();if(oldStream!=null)oldStream.Dispose();caption.Visible=false;picture.Invalidate();return;}
            if(path==shown){caption.Text=name;caption.Visible=true;return;}
            try{
                var ms=new MemoryStream(File.ReadAllBytes(path));var image=Image.FromStream(ms);
                var old=picture.Image;var oldStream=photoHold;picture.Image=image;photoHold=ms;shown=path;
                if(old!=null)old.Dispose();if(oldStream!=null)oldStream.Dispose();
                caption.Text=name;caption.Visible=true;picture.Invalidate();
            }catch(Exception){caption.Text=name+"  已存檔";caption.Visible=true;picture.Invalidate();}
        }
        static string Amount(long n){return n>=1048576?(n/1048576.0).ToString("0.0")+" MB":Math.Max(0,n/1024)+" KB";}
        void ShowPair(string host,string pairing,string print,string payload){
            pairHost=host;pairCode=pairing;pairPrint=print;
            if(string.IsNullOrEmpty(payload))pairVisible=false;
            modules=string.IsNullOrEmpty(payload)?null:QrCode.Modules(payload);
            ApplyPair();
            if(qrWindow!=null&&!qrWindow.IsDisposed)qrWindow.Invalidate(true);
        }
        void RevealPair(){
            if(modules==null)return;
            pairVisible=!pairVisible;
            ApplyPair();
        }
        void ApplyPair(){
            bool live=modules!=null,show=!live||pairVisible;
            address.Text=show?pairHost:"點擊顯示";
            code.Text=show?pairCode:"點擊顯示";
            finger.Text=show?pairPrint:"點擊顯示";
            address.ForeColor=code.ForeColor=finger.ForeColor=show?Ink:Gray;
            address.Font=show&&live?addressFont:smallFont;
            code.Font=show&&live?codeFont:smallFont;
            finger.Font=show&&live?fingerFont:smallFont;
            var cursor=live?Cursors.Hand:Cursors.Default;
            address.Cursor=code.Cursor=finger.Cursor=cursor;
        }
        void PaintQr(Graphics g,Rectangle box){
            g.Clear(Color.White);
            if(modules==null){TextRenderer.DrawText(g,"請先按「開始接收」",Font,box,Gray,TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter|TextFormatFlags.WordBreak);return;}
            int n=modules.GetLength(0),quiet=4,span=n+quiet*2,cell=Math.Max(1,Math.Min(box.Width,box.Height)/span);
            int x0=(box.Width-cell*span)/2,y0=(box.Height-cell*span)/2;
            using(var ink=new SolidBrush(Color.Black))for(int r=0;r<n;r++)for(int c=0;c<n;c++)if(modules[r,c])g.FillRectangle(ink,x0+(c+quiet)*cell,y0+(r+quiet)*cell,cell,cell);
        }
        void OpenQr(){
            if(modules==null){MessageBox.Show("請先按「開始接收」。","配對 QR");return;}
            if(qrWindow!=null&&!qrWindow.IsDisposed){qrWindow.Activate();return;}
            var frame=new Panel{Dock=DockStyle.Fill,BackColor=Color.White,Padding=new Padding(24)};
            var box=new PictureBox{Dock=DockStyle.Fill,BackColor=Color.White};
            box.Paint+=(o,e)=>PaintQr(e.Graphics,box.ClientRectangle);
            frame.Controls.Add(box);
            var hint=new Label{Dock=DockStyle.Bottom,Height=56,BackColor=Paper,ForeColor=Gray,Font=smallFont,TextAlign=ContentAlignment.MiddleCenter,UseMnemonic=false,
                Text="用手機相機掃描，會開啟 Cam Link\r\n配對碼 "+pairCode+"    指紋 "+pairPrint};
            qrWindow=new Form{Text="配對 QR",FormBorderStyle=FormBorderStyle.FixedDialog,StartPosition=FormStartPosition.Manual,MaximizeBox=false,MinimizeBox=false,ShowInTaskbar=false,ClientSize=new Size(380,460),BackColor=Paper,Font=Font};
            qrWindow.Controls.Add(frame);qrWindow.Controls.Add(hint);
            qrWindow.FormClosed+=(o,e)=>{qrWindow=null;};
            qrWindow.Location=new Point(Math.Max(0,Left+(Width-qrWindow.Width)/2),Math.Max(0,Top+(Height-qrWindow.Height)/2));
            qrWindow.Show(this);
        }
        void OpenSavedFolder(){
            try{
                string path=folder.Text.Trim();
                if(path.Length==0)throw new IOException("請先選擇收相資料夾");
                Directory.CreateDirectory(path);
                Process.Start(path);
            }catch(Exception ex){MessageBox.Show(ex.Message,"無法開啟資料夾");}
        }
        void Stop(){
            if(qrWindow!=null&&!qrWindow.IsDisposed)qrWindow.Close();
            if(receiver!=null){receiver.Dispose();receiver=null;}
            run.Text="開始接收";run.BackColor=Warm;run.ForeColor=Color.White;ips.Enabled=folder.Enabled=browse.Enabled=true;
            ShowPair("開始接收後顯示","—","與手機畫面上的 16 位比對",null);
            state.Text=gotCount>0?"接收已停止":"";
            current.Text=gotCount>0?"已停止。已核對的 JPG 留在資料夾。":"照片會出現在左邊";
            speed.Text="";fill.Width=0;
        }
    }
    static class Program {
        [STAThread] static int Main(string[] args){
            if(args.Length>=1&&args[0]=="--qr"){
                string payload=args.Length>=2?args[1]:"camlink://pair?ip=192.168.50.86&code=4c07d5bc1cc8";
                string file=args.Length>=3?args[2]:Path.Combine(Path.GetTempPath(),"camlink-pair-qr.png");
                var m=QrCode.Modules(payload);int n=m.GetLength(0),scale=8,quiet=4,span=n+quiet*2;
                using(var bmp=new Bitmap(span*scale,span*scale))using(var g=Graphics.FromImage(bmp)){
                    g.Clear(Color.White);
                    using(var ink=new SolidBrush(Color.Black))for(int r=0;r<n;r++)for(int c=0;c<n;c++)if(m[r,c])g.FillRectangle(ink,(c+quiet)*scale,(r+quiet)*scale,scale,scale);
                    bmp.Save(file,System.Drawing.Imaging.ImageFormat.Png);
                }
                return 0;
            }
            if(args.Length==3&&args[0]=="--fixture"){
                // Disposable profile for automated acceptance, without touching the operator's settings.
                try{var root=Path.GetFullPath(args[1]);using(var server=new Receiver(IPAddress.Parse(args[2]),Path.Combine(root,"inbox"),Path.Combine(root,"profile"),s=>{})){
                    File.WriteAllText(Path.Combine(root,"pair.tmp"),server.Fingerprint+"\n"+server.Password);
                    for(int i=0;i<180&&!File.Exists(Path.Combine(root,"stop"));i++)Thread.Sleep(1000);
                }return 0;}catch(Exception e){File.WriteAllText(Path.Combine(args[1],"failure.txt"),e.GetType().Name+" "+e.Message);return 1;}
            }
            Application.EnableVisualStyles();Application.Run(new Window());return 0;
        }
    }
}

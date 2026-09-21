import socket,time,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); dst=(sys.argv[1],int(sys.argv[2])); size=int(sys.argv[3]); pps=int(sys.argv[4]); dur=float(sys.argv[5])
payload=b'x'*size; period=1.0/pps; end=time.time()+dur; nxt=time.time(); n=0
while time.time()<end:
    s.sendto(payload,dst); n+=1; nxt+=period
    d=nxt-time.time()
    if d>0: time.sleep(d)
print("sent",n)

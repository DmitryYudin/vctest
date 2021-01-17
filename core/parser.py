from sys import argv

#########################################################
# Entry point
#########################################################

argAmount = len(argv)

if argAmount <= 1:
    raise Exception("No input file specified")
    
with open(argv[1]) as f:
    class Stat:
        numIntra = 0
        numInter = 0
        numSkip = 0
    stat = Stat()
    for line in f:
        if line[0]=='1':
            stat.numSkip = stat.numSkip + 1
            stat.numInter = stat.numInter + 1
        else:
            if line[0] == '0':
                if line[2] == '1':
                    stat.numInter = stat.numInter + 1
                else:
                    if line[2] == '0':
                        stat.numIntra = stat.numIntra + 1
                    else:
                        raise Exception("Second flag expected but not found")
    print("numIntra:%d numInter:%d numSkip:%d" % (stat.numIntra, stat.numInter, stat.numSkip))
